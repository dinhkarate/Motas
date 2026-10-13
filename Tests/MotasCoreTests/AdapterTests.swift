import Foundation
import Testing
@testable import MotasCore

@Suite("CLIProxyAPI adapter")
struct CLIProxyAPIAdapterTests {
    @Test func readsEveryAccountThroughApiCall() async throws {
        let http = cpaTestbed()
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        #expect(snap.health == .ok)
        #expect(snap.accounts.count == 2)

        let codex = try #require(snap.accounts.first { $0.provider == .codex })
        #expect(codex.plan == "free")
        #expect(codex.state == .active)
        #expect(codex.quota.effectiveRemaining == 0)

        let ag = try #require(snap.accounts.first { $0.provider == .antigravity })
        #expect(ag.quota.windows.count == 2)
        #expect(ag.label.hasSuffix("@example.com"))
    }

    @Test func neverCallsQuotaFetchOrDestructiveRoutes() async {
        let http = cpaTestbed()
        _ = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        let paths = Set(http.requests.map(\.path))
        #expect(paths == ["/v0/management/auth-files", "/v0/management/api-call"])
    }

    @Test func codexCallCarriesAccountIdAndTokenPlaceholder() async throws {
        let http = cpaTestbed()
        _ = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        let call = try #require(http.requests.first { ($0.jsonBody["url"] as? String)?.contains("wham") == true })
        let header = try #require(call.jsonBody["header"] as? [String: String])
        #expect(header["Authorization"] == "Bearer $TOKEN$")
        #expect(header["Chatgpt-Account-Id"]?.isEmpty == false)
    }

    @Test func wrongKeyIsUnauthorized() async {
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "nope", http: cpaTestbed()).fetch()
        #expect(snap.health == .unauthorized)
        #expect(snap.accounts.isEmpty)
    }

    @Test func missingKeyIsUnauthorizedWithoutNetwork() async {
        let http = cpaTestbed()
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: nil, http: http).fetch()
        #expect(snap.health == .unauthorized)
        #expect(http.requests.isEmpty)
    }

    @Test func connectionRefusedIsUnreachable() async {
        let http = StubHTTP { _ in throw URLError(.cannotConnectToHost) }
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        #expect(snap.health == .unreachable("Connection refused"))
    }

    @Test func upstreamTokenRejectionFailsTheAccount() async throws {
        let http = StubHTTP { req in
            if req.path == "/v0/management/auth-files" { return (200, Fixture.data("cpa_auth_files"), [:]) }
            return (200, Data(#"{"status_code":401,"header":{},"body":"{\"error\":\"expired\"}"}"#.utf8), [:])
        }
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        let codex = try #require(snap.accounts.first { $0.provider == .codex })
        #expect(codex.quota == .failed("Upstream rejected the account token (401)"))
    }

    @Test func antigravityFallsBackToProdEndpoint() async throws {
        let http = StubHTTP { req in
            if req.path == "/v0/management/auth-files" { return (200, Fixture.data("cpa_auth_files"), [:]) }
            let url = req.jsonBody["url"] as? String ?? ""
            if url.contains("daily-cloudcode") { return (200, Data(#"{"status_code":503,"header":{},"body":""}"#.utf8), [:]) }
            if url.contains("retrieveUserQuotaSummary") { return (200, Fixture.data("cpa_apicall_antigravity_1"), [:]) }
            return (200, Fixture.data("cpa_apicall_codex_usage"), [:])
        }
        let snap = await CLIProxyAPIAdapter(config: cpaConfig, managementKey: "mgmt", http: http).fetch()
        let ag = try #require(snap.accounts.first { $0.provider == .antigravity })
        #expect(ag.quota.windows.count == 2)
    }
}

@Suite("9Router adapter")
struct NineRouterAdapterTests {
    @Test func logsInAndReadsUsage() async throws {
        let http = nineTestbed()
        let snap = await NineRouterAdapter(config: nineConfig, password: "pw", http: http).fetch()
        #expect(snap.health == .ok)
        #expect(snap.accounts.count == 2)

        let codex = try #require(snap.accounts.first { $0.provider == .codex })
        #expect(codex.plan == "free")
        #expect(codex.quota.windows.first?.label == "Session")

        let gemini = try #require(snap.accounts.first { $0.provider == .geminiCLI })
        #expect(gemini.state == .error)
        #expect(gemini.quota == .unavailable("Gemini CLI quota error (429)."))
        #expect(http.requests.first?.path == "/api/auth/login")
    }

    @Test func trailingSlashBaseURLDoesNotDoubleSlash() async {
        let http = nineTestbed()
        _ = await NineRouterAdapter(config: nineConfig, password: "pw", http: http).fetch()
        #expect(http.requests.allSatisfy { !$0.url!.absoluteString.contains("//api") })
    }

    @Test func wrongPasswordIsUnauthorized() async {
        let snap = await NineRouterAdapter(config: nineConfig, password: "bad", http: nineTestbed()).fetch()
        #expect(snap.health == .unauthorized)
    }

    @Test func reusesSessionAcrossRefreshes() async {
        let http = nineTestbed()
        let adapter = NineRouterAdapter(config: nineConfig, password: "pw", http: http)
        _ = await adapter.fetch()
        _ = await adapter.fetch()
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 1)
    }

    @Test func disabledConnectionsAreNotQueried() async throws {
        let http = StubHTTP { req in
            if req.path == "/api/providers" {
                return (200, Data(#"{"connections":[{"id":"c1","provider":"codex","isActive":false,"email":"a@example.com"}]}"#.utf8), [:])
            }
            return (500, Data(), [:])
        }
        let snap = await NineRouterAdapter(config: nineConfig, password: nil, http: http).fetch()
        #expect(snap.accounts.first?.state == .disabled)
        #expect(!http.requests.contains { $0.path.hasPrefix("/api/usage") })
    }
}
