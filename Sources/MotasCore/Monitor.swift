import Foundation
import os

/// Refreshes every enabled proxy concurrently and owns their state: one
/// adapter per proxy, rebuilt when kind, URL, auth or secret changes (so
/// 9Router sessions and login guards survive refreshes), and one
/// `ProxyState`, reset only when kind or URL changes.
public actor Monitor {
    private let http: any HTTPClient
    private let secrets: any SecretStore
    private let now: @Sendable () -> Date
    private var adapters: [UUID: (key: AdapterKey, adapter: any ProxyAdapter)] = [:]
    private var states: [UUID: StateEntry]
    static let log = Logger(subsystem: "dev.motas.app", category: "refresh")

    private struct AdapterKey: Equatable {
        var kind: ProxyKind
        var baseURL: URL
        var auth: ProxyAuth
        var secret: String?
    }

    private struct StateEntry {
        var kind: ProxyKind
        /// nil for a seeded state: the first config of the same kind adopts it.
        var baseURL: URL?
        var state: ProxyState
    }

    /// `seed` is the last saved snapshot; its accounts are carried until the
    /// first refresh that lists them again.
    public init(http: any HTTPClient = URLSessionHTTPClient(), secrets: any SecretStore, seed: Snapshot?,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.http = http
        self.secrets = secrets
        self.now = now
        states = Dictionary((seed?.proxies ?? []).map { ($0.id, StateEntry(kind: $0.kind, state: ProxyState(seed: $0))) }) { a, _ in a }
    }

    /// Reads every enabled proxy concurrently. The secret is read without a
    /// prompt; when Keychain wants approval, fails, or the credential is
    /// missing, the proxy's last accounts are carried.
    public func refresh(_ configs: [ProxyConfig], force: Bool, reason: StaticString) async -> Snapshot {
        let now = now()
        let enabled = configs.filter(\.isEnabled)
        adapters = adapters.filter { id, _ in enabled.contains { $0.id == id } }
        states = states.filter { id, _ in enabled.contains { $0.id == id } }

        var snapshots: [UUID: ProxySnapshot] = [:]
        var work: [(config: ProxyConfig, adapter: any ProxyAdapter, state: ProxyState)] = []
        for config in enabled {
            let state = state(for: config)
            let health: ProxyHealth
            do {
                let secret = try secrets.secret(for: config.id, interactive: false)
                if config.auth.needsSecret, secret?.isEmpty != false {
                    health = .failed(.missingCredential)
                } else {
                    work.append((config, adapter(for: config, secret: secret), state))
                    continue
                }
            } catch SecretStoreError.needsApproval {
                health = .needsKeychainAccess
            } catch {
                health = .failed(.failed("Keychain: \(error)"))
            }
            let snapshot = state.carried(health, config: config, now: now)
            snapshots[config.id] = snapshot
            Self.log.notice("\(config.name, privacy: .private): \(health.logLabel, privacy: .public), carried \(snapshot.accounts.count) (\(reason.description, privacy: .public))")
        }

        let outcomes = await withTaskGroup(of: (Int, ReadOutcome, Duration).self) { group in
            for (index, item) in work.enumerated() {
                group.addTask {
                    let started = ContinuousClock.now
                    let outcome = await ProxyRead.run(item.adapter, state: item.state, now: now, force: force)
                    return (index, outcome, started.duration(to: .now))
                }
            }
            return await group.reduce(into: [(Int, ReadOutcome, Duration)]()) { $0.append($1) }
        }
        for (index, outcome, elapsed) in outcomes {
            let config = work[index].config
            var state = work[index].state
            let snapshot = state.apply(outcome, config: config, now: now)
            states[config.id] = StateEntry(kind: config.kind, baseURL: config.baseURL, state: state)
            snapshots[config.id] = snapshot
            log(config, snapshot, outcome, elapsed: elapsed, reason: reason)
        }
        return Snapshot(fetchedAt: now, proxies: enabled.compactMap { snapshots[$0.id] })
    }

    /// Lists an unsaved config once, for Settings' "Test connection".
    public func test(_ config: ProxyConfig, secret: String?) async -> Result<[AccountDescriptor], ProxyAccessError> {
        do {
            return .success(try await ProxyAdapters.make(config, secret: secret, http: http, now: now).listAccounts())
        } catch {
            return .failure(ProxyAccessError(error))
        }
    }

    private func adapter(for config: ProxyConfig, secret: String?) -> any ProxyAdapter {
        let key = AdapterKey(kind: config.kind, baseURL: config.baseURL, auth: config.auth, secret: secret)
        if let entry = adapters[config.id], entry.key == key { return entry.adapter }
        let adapter = ProxyAdapters.make(config, secret: secret, http: http, now: now)
        adapters[config.id] = (key, adapter)
        return adapter
    }

    /// The proxy's state, reset when its kind or URL changed.
    private func state(for config: ProxyConfig) -> ProxyState {
        var entry = states[config.id] ?? StateEntry(kind: config.kind, state: ProxyState(seed: nil))
        if entry.kind != config.kind || (entry.baseURL ?? config.baseURL) != config.baseURL {
            entry.state = ProxyState(seed: nil)
        }
        states[config.id] = StateEntry(kind: config.kind, baseURL: config.baseURL, state: entry.state)
        return entry.state
    }

    /// One line per proxy; the name is private and no secret is ever logged.
    private func log(_ config: ProxyConfig, _ snapshot: ProxySnapshot, _ outcome: ReadOutcome, elapsed: Duration, reason: StaticString) {
        let reads = Array(outcome.reads.values)
        func count(_ matches: (UsageReading) -> Bool) -> Int { reads.filter(matches).count }
        let ok = count { if case .windows = $0 { true } else { false } }
        let unmetered = count { if case .unavailable = $0 { true } else { false } }
        let rejected = count { if case .failed(let f) = $0, f.kind == .credentialRejected { true } else { false } }
        let listed = (try? outcome.list.get())?.count ?? 0
        let reused = max(0, listed - reads.count - outcome.notStarted)
        let ms = Int(elapsed / .milliseconds(1))
        Self.log.notice("\(config.name, privacy: .private): \(snapshot.health.logLabel, privacy: .public), listed \(listed) read \(reads.count) ok \(ok) failed \(reads.count - ok - unmetered - rejected) rejected \(rejected) unmetered \(unmetered) reused \(reused) not started \(outcome.notStarted) in \(ms) ms (\(reason.description, privacy: .public))")
    }
}

/// One refresh of one proxy, bounded at the source: a read starts only while
/// less than `budget` has elapsed and no read has aborted, and the client
/// caps each request at 20 s. There is no outer deadline, cancellation or
/// timer, so the worst case is the budget plus 20 s.
enum ProxyRead {
    static func run<C: Clock>(_ adapter: any ProxyAdapter, state: ProxyState, now: Date, force: Bool,
                              budget: Duration = .seconds(40), clock: C = ContinuousClock()) async -> ReadOutcome
    where C.Duration == Duration {
        let start = clock.now
        let list: [AccountDescriptor]
        do {
            list = try await adapter.listAccounts()
        } catch {
            return ReadOutcome(list: .failure(ProxyAccessError(error)), reads: [:], abort: nil, notStarted: 0)
        }
        let due = state.due(list, now: now, force: force)
        let stop = OSAllocatedUnfairLock(initialState: Stop())
        let readings = await boundedMap(due, limit: 4) { account -> UsageReading? in
            let starts = stop.withLock { state in
                guard state.abort == nil else { return false }
                guard start.duration(to: clock.now) < budget else {
                    state.notStarted += 1
                    return false
                }
                return true
            }
            guard starts else { return nil }
            do {
                return try await adapter.readUsage(account, force: force)
            } catch {
                stop.withLock { $0.abort = $0.abort ?? ProxyAccessError(error) }
                return nil
            }
        }
        var reads: [String: UsageReading] = [:]
        for (account, reading) in zip(due, readings) { reads[account.id] = reading }
        let ended = stop.withLock { $0 }
        return ReadOutcome(list: .success(list), reads: reads, abort: ended.abort, notStarted: ended.notStarted)
    }

    private struct Stop: Sendable {
        var abort: ProxyAccessError?
        var notStarted = 0
    }
}
