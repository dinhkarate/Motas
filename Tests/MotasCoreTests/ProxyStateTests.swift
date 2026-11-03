import Foundation
import Testing
@testable import MotasCore

let t0 = productionNow
let minute: TimeInterval = 60

func account(_ id: String, _ provider: Provider = .codex, disabled: Bool = false, plan: String? = nil) -> AccountDescriptor {
    AccountDescriptor(id: id, provider: provider, label: id, metadataPlan: plan, isDisabled: disabled)
}

func windows(_ fraction: Double = 0.5, plan: String? = nil, credits: Int? = nil) -> UsageReading {
    .windows([QuotaWindow(id: "session", label: "Primary", remainingFraction: fraction, period: "primary")], plan: plan,
             extras: UsageExtras(resetCredits: credits))
}

let unmetered = UsageReading.unavailable("Usage not available for this connection", recheckAfter: 6 * 3600, extras: UsageExtras())
let timedOut = UsageReading.failed(.transient("Timed out"))
let refreshFailed = UsageReading.failed(.credentialRejected("Credential refresh failed"))

func outcome(_ list: [AccountDescriptor], _ reads: [String: UsageReading] = [:], abort: ProxyAccessError? = nil) -> ReadOutcome {
    ReadOutcome(list: .success(list), reads: reads, abort: abort, notStarted: 0)
}

extension ProxyState {
    /// Applies one read of `account` at `now` and returns its snapshot.
    @discardableResult
    mutating func read(_ account: AccountDescriptor, _ reading: UsageReading, at now: Date) -> AccountSnapshot {
        apply(outcome([account], [account.id: reading]), config: productionConfig, now: now).accounts[0]
    }
}

@Suite("ProxyState")
struct ProxyStateTests {
    let a = account("a")

    @Test func windowsAreStoredWithTheirReadTime() throws {
        var state = ProxyState(seed: nil)
        let snapshot = state.read(account("a", plan: "plus"), windows(0.4, credits: 2), at: t0)
        #expect(snapshot.quota.windows.map(\.remainingFraction) == [0.4])
        #expect(snapshot.quotaObservedAt == t0)
        #expect(snapshot.lastReadError == nil)
        #expect(snapshot.plan == "plus")    // no usage plan: the listing's
        #expect(snapshot.extras.resetCredits == 2)
        let record = try #require(state.records["a"])
        #expect(record.nextReadAt == nil && record.failureStreak == 0 && record.rejectStreak == 0 && record.unavailable == nil)

        // The usage plan wins, and is kept when a later read has none.
        state.read(account("a", plan: "plus"), windows(0.3, plan: "free"), at: t0 + minute)
        #expect(state.read(account("a", plan: "plus"), windows(0.2), at: t0 + 2 * minute).plan == "free")
    }

    @Test func transientFailuresKeepStaleWindowsAndBackOff() throws {
        var state = ProxyState(seed: nil)
        state.read(a, windows(0.7), at: t0)
        var now = t0
        for wait in [5, 10, 20, 40, 60, 60] {
            now += minute
            let snapshot = state.read(a, timedOut, at: now)
            #expect(snapshot.quota.windows.map(\.remainingFraction) == [0.7])
            #expect(snapshot.quotaObservedAt == t0)
            #expect(snapshot.lastReadError == "Timed out")
            #expect(state.records["a"]?.nextReadAt == now + TimeInterval(wait) * minute)
        }
        #expect(state.read(a, windows(0.6), at: now).lastReadError == nil)
        #expect(state.records["a"]?.failureStreak == 0)
    }

    @Test func rateLimitWaitsForItsInstantWhenLater() throws {
        var state = ProxyState(seed: nil)
        state.read(a, .failed(.rateLimited(until: t0 + 120 * minute, "429")), at: t0)
        #expect(state.records["a"]?.nextReadAt == t0 + 120 * minute)
        #expect(state.records["a"]?.rateLimitedUntil == t0 + 120 * minute)
        #expect(state.due([a], now: t0 + 60 * minute, force: true).isEmpty)
        #expect(state.due([a], now: t0 + 120 * minute, force: false).map(\.id) == ["a"])

        var early = ProxyState(seed: nil)
        early.read(a, .failed(.rateLimited(until: t0 + minute, "429")), at: t0)
        #expect(early.records["a"]?.nextReadAt == t0 + 5 * minute)
        var unknown = ProxyState(seed: nil)
        unknown.read(a, .failed(.rateLimited(until: nil, "Too many requests")), at: t0)
        #expect(unknown.records["a"]?.nextReadAt == t0 + 5 * minute)
    }

    @Test func unmeteredWithoutRecentWindowsAtOnce() throws {
        var state = ProxyState(seed: nil)
        let snapshot = state.read(a, unmetered, at: t0)
        #expect(snapshot.quota == .unavailable("Usage not available for this connection"))
        #expect(state.records["a"]?.nextReadAt == t0 + 6 * 3600)

        var stale = ProxyState(seed: nil)
        stale.read(a, windows(0.5), at: t0)
        #expect(stale.read(a, unmetered, at: t0 + 25 * 3600).quota == .unavailable("Usage not available for this connection"))
    }

    @Test func recentWindowsSurviveTwoUnavailableReads() throws {
        var state = ProxyState(seed: nil)
        state.read(a, windows(0.5), at: t0)
        for hour in [1.0, 2.0] {
            let snapshot = state.read(a, unmetered, at: t0 + hour * 3600)
            #expect(snapshot.quota.windows.map(\.remainingFraction) == [0.5])
            #expect(snapshot.lastReadError == "Usage not available for this connection")
            #expect(state.records["a"]?.nextReadAt == t0 + hour * 3600 + (hour == 1 ? 5 : 10) * minute)
        }
        let third = state.read(a, unmetered, at: t0 + 3 * 3600)
        #expect(third.quota == .unavailable("Usage not available for this connection"))
        #expect(state.records["a"]?.windows == nil)
        #expect(state.records["a"]?.nextReadAt == t0 + 9 * 3600)
        #expect(state.records["a"]?.failureStreak == 0)
    }

    @Test func oneRejectionIsReReadTheSecondRejects() throws {
        var state = ProxyState(seed: nil)
        state.read(a, windows(0.5), at: t0)

        let first = state.read(a, refreshFailed, at: t0 + minute)
        #expect(first.quota.windows.map(\.remainingFraction) == [0.5])    // stale, not rejected
        #expect(first.lastReadError == "Credential refresh failed")
        #expect(state.due([a], now: t0 + minute, force: false).map(\.id) == ["a"])

        let second = state.read(a, refreshFailed, at: t0 + 2 * minute)
        #expect(second.quota == .rejected("Credential refresh failed"))
        #expect(second.nextReadAt == t0 + 17 * minute)
        #expect(state.due([a], now: t0 + 3 * minute, force: false).isEmpty)
        #expect(state.due([a], now: t0 + 3 * minute, force: true).map(\.id) == ["a"])
        #expect(state.due([a], now: t0 + 17 * minute, force: false).map(\.id) == ["a"])

        #expect(state.read(a, windows(0.9), at: t0 + 17 * minute).quota.windows.map(\.remainingFraction) == [0.9])
        #expect(state.records["a"]?.rejectStreak == 0)
    }

    @Test func rejectionsMustBeConsecutive() {
        var state = ProxyState(seed: nil)
        state.read(a, refreshFailed, at: t0)
        state.read(a, timedOut, at: t0 + minute)
        #expect(state.read(a, refreshFailed, at: t0 + 2 * minute).quota == .failed("Credential refresh failed"))
    }

    @Test func snapshotQuotaByState() {
        var state = ProxyState(seed: nil)
        let list = [account("never"), account("failed"), account("off", disabled: true)]
        let snapshot = state.apply(outcome(list, ["failed": timedOut]), config: productionConfig, now: t0)
        #expect(snapshot.accounts.map(\.quota) == [.failed("Not read yet"), .failed("Timed out"), .failed("Not read yet")])
        #expect(snapshot.accounts.map(\.state) == [.active, .active, .disabled])
    }

    @Test func healthComesFromTheListing() throws {
        var state = ProxyState(seed: nil)
        let list = [account("a"), account("b")]
        let ok = state.apply(outcome(list, ["a": windows(0.5), "b": windows(0.2)]), config: productionConfig, now: t0)
        #expect(ok.health == .ok)
        #expect(ok.lastSuccessAt == t0 && ok.consecutiveFailures == 0)
        #expect(ok.id == productionConfig.id && ok.name == productionConfig.name && ok.kind == .nineRouter)

        let failed = ReadOutcome(list: .failure(.unreachable("Timed out")), reads: [:], abort: nil, notStarted: 0)
        let down = state.apply(failed, config: productionConfig, now: t0 + minute)
        #expect(down.health == .failed(.unreachable("Timed out")))
        #expect(down.accounts == ok.accounts)    // carried
        #expect(down.consecutiveFailures == 1 && down.lastSuccessAt == t0)
        #expect(state.apply(failed, config: productionConfig, now: t0 + 2 * minute).consecutiveFailures == 2)

        // An abort keeps the reads that completed.
        let aborted = state.apply(outcome(list, ["a": windows(0.1)], abort: .unauthorized("9Router rejected the session")),
                                  config: productionConfig, now: t0 + 3 * minute)
        #expect(aborted.health == .failed(.unauthorized("9Router rejected the session")))
        #expect(aborted.accounts.map(\.quota.effectiveRemaining) == [0.1, 0.2])
        #expect(aborted.consecutiveFailures == 3 && aborted.lastSuccessAt == t0)

        let back = state.apply(outcome(list), config: productionConfig, now: t0 + 4 * minute)
        #expect(back.health == .ok && back.consecutiveFailures == 0 && back.lastSuccessAt == t0 + 4 * minute)
    }

    @Test func carriedNeverCountsAFailure() {
        var state = ProxyState(seed: nil)
        _ = state.apply(ReadOutcome(list: .failure(.offline("Network unavailable")), reads: [:], abort: nil, notStarted: 0),
                        config: productionConfig, now: t0)
        let carried = state.carried(.needsKeychainAccess, config: productionConfig, now: t0 + minute)
        #expect(carried.health == .needsKeychainAccess)
        #expect(carried.consecutiveFailures == 1 && carried.fetchedAt == t0 + minute)
        #expect(state.consecutiveFailures == 1)
    }

    @Test func accountsMissingFromASuccessfulListAreDropped() {
        var state = ProxyState(seed: nil)
        _ = state.apply(outcome([account("a"), account("b")], ["a": windows(), "b": windows()]), config: productionConfig, now: t0)
        let snapshot = state.apply(outcome([account("b")]), config: productionConfig, now: t0 + minute)
        #expect(snapshot.accounts.map(\.id) == ["b"])
        #expect(Set(state.records.keys) == ["b"])
        #expect(snapshot.accounts[0].quota.windows.count == 1)    // b's record survived
    }

    @Test func dueOrderAndForce() {
        let older = account("older"), newer = account("newer"), failed = account("failed"), never = account("never"),
            rejected = account("rejected"), unmeteredDue = account("unmetered"), off = account("off", disabled: true),
            waiting = account("waiting"), limited = account("limited"), parked = account("parked")
        let history: [(AccountDescriptor, UsageReading, Date)] = [
            (newer, windows(), t0), (older, windows(), t0 - minute), (failed, timedOut, t0 - 10 * minute),
            (rejected, refreshFailed, t0 - 40 * minute), (rejected, refreshFailed, t0 - 30 * minute),
            (unmeteredDue, unmetered, t0 - 7 * 3600), (waiting, timedOut, t0),
            (limited, .failed(.rateLimited(until: t0 + 3600, "429")), t0), (parked, unmetered, t0),
        ]
        var state = ProxyState(seed: nil)
        for (account, reading, at) in history {
            state.records[account.id, default: AccountRecord()].apply(reading, metadataPlan: nil, now: at)
        }
        let list = [unmeteredDue, parked, limited, rejected, failed, off, never, waiting, newer, older]
        #expect(state.due(list, now: t0 + minute, force: false).map(\.id) == ["older", "newer", "never", "rejected", "failed", "unmetered"])
        #expect(state.due(list, now: t0 + minute, force: true).map(\.id)
                == ["older", "newer", "never", "rejected", "failed", "waiting", "unmetered"])
    }

    @Test func seedingFromTheLegacySnapshot() throws {
        let legacy = try #require(SharedSnapshot.load(from: Fixture.url("snapshot_v0.2", dir: "legacy")))
        let home = try #require(legacy.snapshot.proxies.first { $0.name == "Home 9Router" })
        let state = ProxyState(seed: home)
        #expect(state.consecutiveFailures == 0 && state.lastSuccessAt == nil)
        #expect(state.accounts.count == 6)

        let byID = Dictionary(uniqueKeysWithValues: state.accounts.map { (String($0.id.suffix(3)), $0) })
        #expect(byID["028"]?.quotaObservedAt == home.fetchedAt)    // 0.2 windows were read at fetchedAt
        #expect(byID["007"]?.state == .active)                      // 0.2 "error"
        #expect(byID["048"]?.state == .disabled)
        #expect(state.records["00000000-0000-4000-8000-000000000028"]?.observedAt == home.fetchedAt)
        #expect(state.records["00000000-0000-4000-8000-000000000001"]?.unavailable == "Qoder connected. Usage fetch returned 401.")
        #expect(state.records["00000000-0000-4000-8000-000000000060"]?.lastError == "Token refresh failed on 9Router")

        let list = state.accounts.map { AccountDescriptor(id: $0.id, provider: $0.provider, label: $0.label, isDisabled: $0.state == .disabled) }
        #expect(state.due(list, now: home.fetchedAt + minute, force: false).map { String($0.id.suffix(3)) } == ["028", "007", "004", "060", "001"])

        let carried = state.carried(.needsKeychainAccess, config: productionConfig, now: t0)
        #expect(carried.accounts.map(\.id) == home.accounts.map(\.id))
        #expect(carried.accounts.allSatisfy { if case .windows = $0.quota { $0.quotaObservedAt == home.fetchedAt } else { true } })

        let rejected = AccountSnapshot(id: "r", provider: .codex, label: "r", state: .active, quota: .rejected("Credential refresh failed"))
        let reseeded = ProxyState(seed: ProxySnapshot(id: UUID(), name: "p", kind: .nineRouter, fetchedAt: t0, health: .ok, accounts: [rejected]))
        #expect(reseeded.records["r"]?.isRejected == true)
    }
}

@Suite("ProxyRead.run")
struct ProxyReadTests {
    @Test func budgetStopsNewReadsWithoutSleeping() async throws {
        let clock = TestClock()
        let http = nineServer(tokens: [productionToken]) { req in
            guard req.path.hasPrefix("/api/usage/") else { return productionReply(req) }
            clock.advance(by: .seconds(20))    // what the 20 s resource timeout costs
            throw URLError(.timedOut)
        }
        let adapter = NineRouterAdapter(config: productionConfig, secret: productionToken, http: http, now: { t0 })
        let started = ContinuousClock.now
        let result = await ProxyRead.run(adapter, state: ProxyState(seed: nil), now: t0, force: false, budget: .seconds(40), clock: clock)
        #expect(started.duration(to: .now) < .seconds(5))

        // 26 active connections are due; a read starts only while less than
        // 40 s have passed, and at most 4 run at once.
        #expect((2...5).contains(result.reads.count))
        #expect(result.notStarted == 26 - result.reads.count)
        #expect(result.abort == nil)
        #expect(result.reads.values.allSatisfy { $0 == timedOut })
        #expect(http.requests.filter { $0.path.hasPrefix("/api/usage/") }.count == result.reads.count)

        // Reads that never started keep their state and are not failures.
        var state = ProxyState(seed: nil)
        let snapshot = state.apply(result, config: productionConfig, now: t0)
        #expect(snapshot.health == .ok)
        #expect(snapshot.accounts.filter { $0.quota == .failed("Not read yet") }.count == 29 - result.reads.count)
    }

    @Test func anAbortStopsLaterReads() async throws {
        let http = nineServer(tokens: [productionToken]) { req in req.path == "/api/providers" ? productionReply(req) : sessionRejected }
        let adapter = NineRouterAdapter(config: productionConfig, secret: productionToken, http: http, now: { t0 })
        let result = await ProxyRead.run(adapter, state: ProxyState(seed: nil), now: t0, force: false)
        #expect(result.abort == tokenRejected)
        #expect(result.reads.isEmpty)
        #expect(result.notStarted == 0)
        #expect((1...4).contains(http.requests.filter { $0.path.hasPrefix("/api/usage/") }.count))

        var state = ProxyState(seed: nil)
        let snapshot = state.apply(result, config: productionConfig, now: t0)
        #expect(snapshot.health == .failed(tokenRejected))
        #expect(!snapshot.accounts.contains { if case .rejected = $0.quota { true } else { false } })
        #expect(snapshot.consecutiveFailures == 1)
    }

    @Test func listingErrorsAreMapped() async {
        for (error, expected) in [(URLError(.cannotConnectToHost), ProxyAccessError.unreachable("Connection refused")),
                                  (URLError(.notConnectedToInternet), .offline("Network unavailable"))] {
            let adapter = NineRouterAdapter(config: productionConfig, secret: productionToken, http: StubHTTP { _ in throw error })
            let result = await ProxyRead.run(adapter, state: ProxyState(seed: nil), now: t0, force: false)
            guard case .failure(let failure) = result.list else { Issue.record("expected a failed listing"); continue }
            #expect(failure == expected)
            #expect(result.reads.isEmpty)
        }
    }

    @Test func readsOnlyWhatIsDue() async throws {
        let http = nineProduction()
        let adapter = NineRouterAdapter(config: productionConfig, secret: productionToken, http: http, now: { t0 })
        var state = ProxyState(seed: nil)
        let first = await ProxyRead.run(adapter, state: state, now: t0, force: false)
        #expect(first.reads.count == 26)    // disabled connections are never read
        _ = state.apply(first, config: productionConfig, now: t0)

        // Ten minutes later: unmetered accounts wait 6 h; the rest are read again.
        let second = await ProxyRead.run(adapter, state: state, now: t0 + 10 * minute, force: false)
        #expect(second.reads.count == 26 - 6)
        #expect(!second.reads.keys.contains("00000000-0000-4000-8000-000000000002"))
        let snapshot = state.apply(second, config: productionConfig, now: t0 + 10 * minute)

        // Qoder: one rejection is re-read, the second rejects.
        let qoder = snapshot.accounts.filter { $0.provider == Provider(rawValue: "qoder") }
        #expect(qoder.filter { $0.quota == .rejected("Qoder connected. Usage fetch returned 401.") }.count == 9)
        #expect(qoder.filter { $0.quota == .unavailable("No figures (Qoder reports quota exceeded)") }.count == 1)
    }
}
