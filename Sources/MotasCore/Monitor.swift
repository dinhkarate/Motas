import Foundation
import os

/// Refreshes every enabled proxy concurrently. Keeps one adapter per proxy
/// (so 9Router sessions are reused) and rebuilds it when its config or
/// secret changes.
public actor Monitor {
    private let http: any HTTPClient
    private var adapters: [UUID: (key: String, adapter: any ProxyAdapter)] = [:]
    /// A proxy that has not answered by then is reported unreachable, so one
    /// slow server never delays the whole refresh.
    let deadline: Duration
    static let log = Logger(subsystem: "dev.motas.app", category: "refresh")

    public init(http: any HTTPClient = URLSessionHTTPClient(), deadline: Duration = .seconds(60)) {
        self.http = http
        self.deadline = deadline
    }

    public func refresh(_ configs: [ProxyConfig], secrets: any SecretStore, now: Date = Date()) async -> Snapshot {
        let enabled = configs.filter(\.isEnabled)
        adapters = adapters.filter { id, _ in enabled.contains { $0.id == id } }

        var work: [(Int, any ProxyAdapter, ProxyConfig)] = []
        var failures: [Int: ProxySnapshot] = [:]
        for (index, config) in enabled.enumerated() {
            let secret: String?
            do {
                secret = try secrets.secret(for: config.id, interactive: false)
            } catch SecretStoreError.needsApproval {
                failures[index] = ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now,
                                                health: .needsKeychainAccess, accounts: [])
                continue
            } catch {
                failures[index] = ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now,
                                                health: .failed("Keychain: \(error)"), accounts: [])
                continue
            }
            let key = "\(config.kind)|\(config.baseURL.absoluteString)|\(config.name)|\((secret ?? "").hashValue)"
            if adapters[config.id]?.key != key {
                adapters[config.id] = (key, ProxyAdapters.make(config, secret: secret, http: http))
            }
            work.append((index, adapters[config.id]!.adapter, config))
        }

        let started = ContinuousClock.now
        let deadline = self.deadline
        let fetched = await withTaskGroup(of: (Int, ProxySnapshot).self) { group in
            for (index, adapter, config) in work {
                group.addTask { (index, await Self.fetch(adapter, config: config, now: now, deadline: deadline)) }
            }
            var out: [Int: ProxySnapshot] = [:]
            for await (index, snap) in group { out[index] = snap }
            return out
        }
        let all = fetched.merging(failures) { a, _ in a }
        let snapshot = Snapshot(fetchedAt: now, proxies: all.keys.sorted().map { all[$0]! })
        let summary = snapshot.proxies.map { "\($0.name)=\($0.health.logLabel)/\($0.accounts.count)" }.joined(separator: " ")
        let d = ContinuousClock.now - started
        let elapsed = "\(d.components.seconds * 1000 + d.components.attoseconds / 1_000_000_000_000_000) ms"
        Self.log.notice("refresh \(snapshot.proxies.count) proxies in \(elapsed, privacy: .public): \(summary, privacy: .public)")
        return snapshot
    }

    /// Runs one adapter against the deadline; whichever finishes first wins.
    /// The loser is cancelled and not awaited, so an adapter that ignores
    /// cancellation cannot hold the refresh past the deadline.
    static func fetch(_ adapter: any ProxyAdapter, config: ProxyConfig, now: Date, deadline: Duration) async -> ProxySnapshot {
        let timedOut = ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now,
                                     health: .unreachable("No answer within \(deadline.formatted())"), accounts: [])
        let first = FirstResult<ProxySnapshot>()
        return await withCheckedContinuation { continuation in
            first.continuation = continuation
            let work = Task { first.resume(with: await adapter.fetch()) }
            Task {
                try? await Task.sleep(for: deadline)
                if first.resume(with: timedOut) {
                    work.cancel()
                    log.error("\(config.name, privacy: .public) gave no answer within \(deadline)")
                }
            }
        }
    }

    /// One-off read with an unsaved config, for Settings' "Test connection".
    public func test(_ config: ProxyConfig, secret: String?) async -> ProxySnapshot {
        await ProxyAdapters.make(config, secret: secret, http: http).fetch()
    }
}

/// Resumes a continuation exactly once, with whichever value arrives first.
final class FirstResult<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, Never>?

    @discardableResult
    func resume(with value: T) -> Bool {
        let c: CheckedContinuation<T, Never>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        c?.resume(returning: value)
        return c != nil
    }
}
