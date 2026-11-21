import Foundation
import Testing
@testable import MotasCore

@Suite("Orca")
struct OrcaTests {
    /// The capture's newest `updatedAt`, plus a minute.
    let captured = Date(timeIntervalSince1970: 1_795_281_577)

    func listing(now: Date? = nil) throws -> OrcaAdapter.Listing {
        try OrcaAdapter.parse(Fixture.data("orca_account_list"), now: now ?? captured)
    }

    func windows(_ reading: UsageReading?) -> [QuotaWindow] {
        if case .windows(let windows, _, _) = reading { return windows }
        return []
    }

    @Test func managedAccountsThenSignedInCLIs() throws {
        let listing = try listing()
        #expect(listing.accounts.map(\.provider.rawValue) == ["claude", "claude", "codex", "codex", "codex", "antigravity", "grok"])
        #expect(listing.accounts.prefix(5).allSatisfy { $0.label.hasSuffix("@example.com") })
        #expect(listing.accounts[3].metadataPlan == "plus" && listing.accounts[2].metadataPlan == "free")
        // Codex accounts dedupe with proxies by their ChatGPT account id.
        #expect(listing.accounts[2].identity?.contains("@") == false)
    }

    @Test func activeAndInactiveAccountsCarryTheirOwnWindows() throws {
        let listing = try listing()
        let active = listing.readings["claude:0ca00001-0000-4000-8000-000000000002"]
        guard case .windows(let claude, let plan, _) = active else { Issue.record("no windows"); return }
        #expect(plan == "pro")
        #expect(claude.map(\.period) == ["5h", "weekly", "weekly"] && claude.map(\.role) == [.limit, .limit, .detail])
        #expect(abs(claude[0].remainingFraction - 0.61) < 1e-9 && claude[0].label == "5-hour" && claude[2].label == "Fable · Weekly")
        #expect(claude[0].resetsAt == Date(timeIntervalSince1970: 1_795_296_000))
        guard case .windows(_, let team, _) = listing.readings["claude:0ca00003-0000-4000-8000-000000000004"] else {
            Issue.record("inactive Claude account unread"); return
        }
        #expect(team == "team")
    }

    @Test func codexRevokedFreeAndExhausted() throws {
        let listing = try listing()
        guard case .failed(let revoked) = listing.readings["codex:0ca00009-0000-4000-8000-00000000000a"] else {
            Issue.record("revoked account read"); return
        }
        #expect(revoked.kind == .credentialRejected && !revoked.message.contains("body"))
        guard case .windows(let free, "free", let extras) = listing.readings["codex:0ca00005-0000-4000-8000-000000000006"] else {
            Issue.record("free account unread"); return
        }
        #expect(free.map(\.period) == ["5h"] && extras.resetCredits == 1)
        let plus = windows(listing.readings["codex:0ca00007-0000-4000-8000-000000000008"])
        #expect(plus.first { $0.period == "weekly" }?.remainingFraction == 0)
    }

    @Test func antigravityBucketsBecomeFamilies() throws {
        let antigravity = windows(try listing().readings["antigravity"])
        #expect(Set(antigravity.compactMap(\.group)) == ["gemini", "claude-gpt"])
        #expect(antigravity.count == 4 && antigravity.allSatisfy { $0.role == .limit })
        #expect(antigravity.first?.label == "Gemini · Weekly")
    }

    @Test func oldFiguresAreNotCurrent() throws {
        let reading = try listing(now: captured + 4 * 3600).readings["grok"]
        guard case .failed(let failure) = reading else { Issue.record("stale figures shown"); return }
        #expect(failure.kind == .transient)
    }

    @Test func aRefusalIsAProxyProblem() {
        #expect(throws: ProxyAccessError.unreachable("Orca is not running")) {
            try OrcaAdapter.parse(Data(#"{"ok":false,"error":{"message":"Orca is not running"}}"#.utf8), now: captured)
        }
        #expect(throws: ProxyAccessError.failed("Orca returned no JSON")) { try OrcaAdapter.parse(Data("hello".utf8), now: captured) }
    }

    @Test func theAdapterRunsTheCLIOncePerListing() async throws {
        let calls = OSAllocatedUnfairLockBox()
        let config = ProxyConfig(name: "Orca", kind: .orca, baseURL: URL(fileURLWithPath: "/bin/ls"))
        #expect(config.auth == .none && !config.auth.usesSecret)
        let adapter = OrcaAdapter(config: config, run: { url, arguments in
            calls.add("\(url.path) \(arguments.joined(separator: " "))")
            return Fixture.data("orca_account_list")
        }, now: { [captured] in captured })
        let accounts = try await adapter.listAccounts()
        for account in accounts { _ = try await adapter.readUsage(account, force: false) }
        #expect(calls.values == ["/bin/ls account list --json"])
        #expect(config.dashboardURL == config.baseURL)
        let app = ProxyConfig(name: "Orca", kind: .orca, baseURL: OrcaAdapter.defaultCLI)
        #expect(app.dashboardURL.path == "/Applications/Orca.app")
    }
}

final class OSAllocatedUnfairLockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func add(_ value: String) { lock.withLock { _values.append(value) } }
    var values: [String] { lock.withLock { _values } }
}
