import Foundation
import Testing
@testable import MotasCore

@Suite("9Router adapter")
struct NineRouterAdapterTests {
    func adapter(_ http: StubHTTP, config: ProxyConfig = productionConfig, secret: String? = productionToken,
                 now: TestNow = TestNow()) -> NineRouterAdapter {
        NineRouterAdapter(config: config, secret: secret, http: http, now: now.function)
    }

    /// Lists, then reads every connection in turn, disabled ones included.
    func readAll(_ adapter: NineRouterAdapter, force: Bool = false) async throws -> [String: UsageReading] {
        var readings: [String: UsageReading] = [:]
        for account in try await adapter.listAccounts() {
            readings[account.id] = try await adapter.readUsage(account, force: force)
        }
        return readings
    }

    @Test func productionListing() async throws {
        let accounts = try await adapter(nineProduction()).listAccounts()
        #expect(accounts.count == 29)
        #expect(accounts.filter { !$0.isDisabled }.count == 26)
        #expect(Set(accounts.filter(\.isDisabled).map { String($0.id.suffix(3)) }) == ["016", "048", "051"])

        let codex = try #require(accounts.first { $0.id.hasSuffix("007") })
        #expect(codex.provider == .codex)
        #expect(codex.label == "account3@example.com")
        #expect(codex.identity == "00000000-0000-4000-8000-000000000006")
        #expect(codex.metadataPlan == "plus")
        let luna = try #require(Dates.iso("2026-11-02T16:25:31.621Z"))
        #expect(codex.lockedModels == ["gpt-6-luna": luna])   // past locks dropped
        #expect(codex.cooldownUntil == nil)
        #expect(codex.proxyNote == ProxyNote(message: "[429]: The usage limit has been reached", at: Dates.iso("2026-11-02T15:55:31.621Z")))
        #expect(codex.locator == .nineRouter)

        let node = try #require(accounts.first { $0.id.hasSuffix("002") })
        #expect(node.label == "Connection 2")
        #expect(node.displayHint == "quotax-oss")
        #expect(node.identity == nil)

        let qoder = try #require(accounts.first { $0.id.hasSuffix("010") })
        #expect(qoder.label == "account2@example.com")
        #expect(qoder.identity == "account2@example.com")
        #expect(qoder.displayHint == nil)
    }

    @Test func descriptorCooldownIsTheLatestFutureLock() throws {
        let connection: [String: Any] = [
            "id": "c1", "provider": "codex", "isActive": true,
            "rateLimitedUntil": "2026-11-02T16:30:00.000Z", "modelLock___all": "2026-11-02T17:00:00.000Z",
            "modelLock_gpt-5": "2026-11-02T16:00:00.000Z", "modelLock_gpt-6": NSNull(),
            "providerSpecificData": ["chatgptPlanType": "unknown"],
        ]
        let account = try #require(NineRouterAdapter.descriptor(connection, now: productionNow))
        #expect(account.cooldownUntil == Dates.iso("2026-11-02T17:00:00.000Z"))
        #expect(account.lockedModels.isEmpty)
        #expect(account.metadataPlan == nil)
        #expect(account.label == "c1")
        #expect(NineRouterAdapter.descriptor(["provider": "codex"], now: productionNow) == nil)
    }

    @Test func everyProductionConnectionReads() async throws {
        let readings = try await readAll(adapter(nineProduction()))
        #expect(readings.count == 29)
        let kinds = Dictionary(grouping: readings.values.map { summary($0).prefix { $0 != " " && $0 != "(" && $0 != ":" } }) { $0 }
            .mapValues(\.count)
        #expect(kinds == ["windows": 11, "credentialRejected": 11, "unavailable": 7])
        #expect(summary(try #require(readings["00000000-0000-4000-8000-000000000048"]))
                == "credentialRejected: Credential refresh failed: Refresh token invalid or reused. Please re-authorize the connection.")
        #expect(summary(try #require(readings["00000000-0000-4000-8000-000000000013"])) == "windows Primary=0 plan=go credits=2")
    }

    /// Nothing but the three endpoints, with valid ids; the token on providers
    /// and usage only, the password only in the login body.
    @Test func requestWhitelist() async throws {
        let token = nineProduction()
        _ = try await readAll(adapter(token), force: true)
        _ = try await readAll(adapter(token), force: false)
        let password = nineProduction(tokens: [], password: "pw")
        var passwordConfig = productionConfig
        passwordConfig.auth = .password
        _ = try await readAll(adapter(password, config: passwordConfig, secret: "pw"), force: true)

        for request in token.requests + password.requests {
            let path = request.path
            let id = path.hasPrefix("/api/usage/") ? String(path.dropFirst("/api/usage/".count)) : nil
            switch (request.httpMethod ?? "GET", path) {
            case ("GET", "/api/providers"):
                #expect(request.url?.query == nil)
            case ("POST", "/api/auth/login"):
                #expect(request.jsonBody["password"] as? String == "pw")
                #expect(request.value(forHTTPHeaderField: "x-9r-cli-token") == nil)
                #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            case ("GET", _) where id?.wholeMatch(of: /[A-Za-z0-9_-]{1,128}/) != nil:
                #expect([nil, "force=1"].contains(request.url?.query))
            default:
                Issue.record("unexpected request \(request.httpMethod ?? "") \(path)")
            }
        }
        #expect(token.requests.allSatisfy { $0.value(forHTTPHeaderField: "x-9r-cli-token") == productionToken })
        #expect(!token.requests.contains { $0.path == "/api/auth/login" || $0.value(forHTTPHeaderField: "Cookie") != nil })
        #expect(token.requests.filter { $0.url?.query == "force=1" }.count == 29)
        #expect(password.requests.filter { $0.path == "/api/auth/login" }.count == 1)
        #expect(password.requests.filter { $0.path != "/api/auth/login" }.allSatisfy {
            $0.value(forHTTPHeaderField: "Cookie") == "auth_token=jwt123" && $0.value(forHTTPHeaderField: "x-9r-cli-token") == nil
        })
    }

    @Test(arguments: ["", "../api/shutdown", "a/b", "id?x=1", "id with space", "%2e%2e", String(repeating: "a", count: 129)])
    func unexpectedIdsAreNeverRequested(_ id: String) async throws {
        let http = nineProduction()
        let reading = try await adapter(http).readUsage(AccountDescriptor(id: id, provider: .codex, label: "x"), force: false)
        #expect(summary(reading) == "transient: Unexpected connection id")
        #expect(http.requests.isEmpty)
    }

    @Test func trailingSlashBaseURLDoesNotDoubleSlash() async throws {
        let http = nineTestbed()
        _ = try await readAll(adapter(http, config: nineConfig, secret: "pw"))
        #expect(http.requests.allSatisfy { !$0.url!.absoluteString.contains("//api") })
    }

    @Test func sessionRejectionWithTokenIsUnauthorized() async throws {
        let http = StubHTTP { _ in sessionRejected }
        await #expect(throws: tokenRejected) { try await adapter(http).listAccounts() }
        await #expect(throws: tokenRejected) {
            try await adapter(http).readUsage(AccountDescriptor(id: "c1", provider: .codex, label: "x"), force: false)
        }
        #expect(http.requests.count == 2)    // no retry, no login
    }

    @Test func withoutASecretNoCredentialIsSentAndA401MeansMissing() async throws {
        let http = nineProduction()
        await #expect(throws: ProxyAccessError.missingCredential) { try await adapter(http, secret: "").listAccounts() }
        let request = try #require(http.requests.first)
        #expect(request.value(forHTTPHeaderField: "x-9r-cli-token") == nil && request.value(forHTTPHeaderField: "Cookie") == nil)

        // A 9Router without login: password mode with no password just reads.
        let open = StubHTTP(productionReply)
        #expect(try await adapter(open, config: nineConfig, secret: nil).listAccounts().count == 29)
        #expect(open.requests.allSatisfy { $0.path != "/api/auth/login" })
    }

    /// The server rotates its session secret: every cookie it issued is now
    /// refused. Concurrent readers share one login and retry once.
    @Test func sessionRejectionWithPasswordReLogsInOnceAndRetries() async throws {
        let generation = Counter(1)
        let http = StubHTTP { req in
            if req.path == "/api/auth/login" { return loginAccepted(cookie: "jwt\(generation.value)") }
            guard req.value(forHTTPHeaderField: "Cookie") == "auth_token=jwt\(generation.value)" else { return sessionRejected }
            return productionReply(req)
        }
        let nine = adapter(http, config: nineConfig, secret: "pw")
        let accounts = try await nine.listAccounts()
        generation.value = 2

        let readings = await withTaskGroup(of: UsageReading?.self) { group in
            for account in accounts.prefix(8) { group.addTask { try? await nine.readUsage(account, force: false) } }
            return await group.reduce(into: [UsageReading]()) { if let r = $1 { $0.append(r) } }
        }
        #expect(readings.count == 8)
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 2)
        // The session 401s never reached an account: only Qoder's own message rejects one.
        #expect(readings.map(summary).filter { $0.hasPrefix("credentialRejected") } == ["credentialRejected: Qoder connected. Usage fetch returned 401."])

        generation.value = 3
        #expect(try await nine.listAccounts().count == 29)
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 3)
    }

    @Test func aSessionRefusedTwiceIsUnauthorized() async throws {
        let http = StubHTTP { req in req.path == "/api/auth/login" ? loginAccepted() : sessionRejected }
        await #expect(throws: ProxyAccessError.unauthorized("9Router rejected the session")) {
            try await adapter(http, config: nineConfig, secret: "pw").listAccounts()
        }
        #expect(http.requests.map(\.path) == ["/api/auth/login", "/api/providers", "/api/auth/login", "/api/providers"])
    }

    @Test func sessionIsReusedFor23Hours() async throws {
        let http = nineTestbed()
        let now = TestNow()
        let nine = adapter(http, config: nineConfig, secret: "pw", now: now)
        _ = try await nine.listAccounts()
        now.advance(22 * 3600)
        _ = try await nine.listAccounts()
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 1)
        now.advance(3600)
        _ = try await nine.listAccounts()
        #expect(http.requests.filter { $0.path == "/api/auth/login" }.count == 2)
    }

    @Test func wrongPasswordStopsLoginsFor30Minutes() async throws {
        let http = nineTestbed()
        let now = TestNow()
        let nine = adapter(http, config: nineConfig, secret: "bad", now: now)
        for _ in 0..<3 {
            await #expect(throws: ProxyAccessError.unauthorized("Wrong password")) { try await nine.listAccounts() }
        }
        #expect(http.requests.count == 1)
        now.advance(30 * 60)
        await #expect(throws: ProxyAccessError.unauthorized("Wrong password")) { try await nine.listAccounts() }
        #expect(http.requests.count == 2)
    }

    /// A locked login, then no login before `seconds` have passed.
    func expectLockout(_ reply: StubHTTP.Reply, seconds: TimeInterval) async throws {
        let http = StubHTTP { _ in reply }
        let now = TestNow()
        let nine = adapter(http, config: nineConfig, secret: "pw", now: now)
        let until = productionNow.addingTimeInterval(seconds)
        await #expect(throws: ProxyAccessError.loginLocked(until: until)) { try await nine.listAccounts() }
        now.advance(seconds - 1)
        await #expect(throws: ProxyAccessError.loginLocked(until: until)) { try await nine.listAccounts() }
        #expect(http.requests.count == 1)
        now.advance(1)
        _ = try? await nine.listAccounts()
        #expect(http.requests.count == 2)
    }

    @Test func lockedLoginWaitsForTheBodysRetryAfter() async throws {
        try await expectLockout((429, Data(#"{"error":"Too many failed attempts","retryAfter":120}"#.utf8), ["Retry-After": "600"]), seconds: 120)
    }

    @Test func lockedLoginFallsBackToTheHeaderThenOneMinute() async throws {
        try await expectLockout((429, Data(#"{"error":"Too many failed attempts"}"#.utf8), ["Retry-After": "600"]), seconds: 600)
        try await expectLockout((429, Data(#"{"error":"Too many failed attempts"}"#.utf8), [:]), seconds: 60)
    }

    @Test(arguments: [
        (Fixture.data("9r_login_password_disabled", dir: "synthetic"), "Password login is disabled on this 9Router — use a CLI token"),
        (Data(#"{"error":"Password login is disabled. Use SAML SSO sign in."}"#.utf8), "Password login is disabled on this 9Router — use a CLI token"),
        (Data(#"{"error":"Default password must be changed before remote access. Open the dashboard locally."}"#.utf8),
         "Change the default 9Router password first, or use a CLI token"),
    ])
    func forbiddenLoginStopsLoginsFor30Minutes(_ body: Data, _ message: String) async throws {
        let http = StubHTTP { _ in (403, body, [:]) }
        let now = TestNow()
        let nine = adapter(http, config: nineConfig, secret: "pw", now: now)
        await #expect(throws: ProxyAccessError.unauthorized(message)) { try await nine.listAccounts() }
        now.advance(29 * 60)
        await #expect(throws: ProxyAccessError.unauthorized(message)) { try await nine.listAccounts() }
        #expect(http.requests.count == 1)
    }

    @Test func otherLoginFailuresAreNotGuarded() async throws {
        let http = StubHTTP { _ in (500, Data(), [:]) }
        let nine = adapter(http, config: nineConfig, secret: "pw")
        await #expect(throws: ProxyAccessError.failed("Login HTTP 500")) { try await nine.listAccounts() }
        await #expect(throws: ProxyAccessError.failed("Login HTTP 500")) { try await nine.listAccounts() }
        #expect(http.requests.count == 2)
    }

    @Test func redirectsAreRefused() async throws {
        let http = StubHTTP { _ in (302, Data(), ["Location": "https://login.example.net/api/providers"]) }
        await #expect(throws: ProxyAccessError.failed("Redirected to login.example.net — use the final URL in Settings")) {
            try await adapter(http).listAccounts()
        }
        await #expect(throws: ProxyAccessError.failed("Redirected to login.example.net — use the final URL in Settings")) {
            try await adapter(http).readUsage(AccountDescriptor(id: "c1", provider: .codex, label: "x"), force: false)
        }
        await #expect(throws: ProxyAccessError.failed("Redirected to login.example.net — use the final URL in Settings")) {
            try await adapter(http, config: nineConfig, secret: "pw").listAccounts()
        }
    }

    @Test func plainHTTPToAPublicHostIsRefusedBeforeSending() async throws {
        let http = nineProduction()
        let config = ProxyConfig(name: "public", kind: .nineRouter, baseURL: URL(string: "http://router.example.com:20128")!)
        await #expect(throws: ProxyAccessError.failed("Refusing to send the secret over plain HTTP to router.example.com")) {
            try await adapter(http, config: config).listAccounts()
        }
        var password = config
        password.auth = .password
        await #expect(throws: ProxyAccessError.failed("Refusing to send the secret over plain HTTP to router.example.com")) {
            try await adapter(http, config: password, secret: "pw").listAccounts()
        }
        #expect(http.requests.isEmpty)

        for host in ["10.0.0.5", "127.0.0.1", "nas.local"] {
            let local = ProxyConfig(name: host, kind: .nineRouter, baseURL: URL(string: "http://\(host):20128")!)
            #expect(try await adapter(nineProduction(), config: local).listAccounts().count == 29)
        }
    }

    @Test func usageStatusMapping() async throws {
        let replies: [String: StubHTTP.Reply] = [
            "a": (401, Fixture.data("9r_prod_usage_codex_refresh_failed"), [:]),
            "b": (403, Data(#"{"error":"Forbidden"}"#.utf8), [:]),
            "c": (404, Fixture.data("9r_usage_not_found", dir: "synthetic"), [:]),
            "d": (429, Data(), ["Retry-After": "120"]),
            "e": (500, Fixture.data("9r_usage_route_500", dir: "synthetic"), [:]),
            "f": (502, Data("<html>".utf8), [:]),
        ]
        let http = StubHTTP { req in
            if let reply = replies[String(req.path.dropFirst("/api/usage/".count))] { return reply }
            throw URLError(req.path.hasSuffix("/g") ? .timedOut : .notConnectedToInternet)
        }
        let nine = adapter(http)
        func read(_ id: String) async throws -> String { summary(try await nine.readUsage(AccountDescriptor(id: id, provider: .codex, label: id), force: false)) }
        #expect(try await read("a") == "credentialRejected: Credential refresh failed: Refresh token invalid or reused. Please re-authorize the connection.")
        #expect(try await read("b") == "credentialRejected: Forbidden")
        #expect(try await read("c") == "transient: Connection no longer on the proxy")
        #expect(try await read("d") == "rateLimited(\(productionNow.addingTimeInterval(120).timeIntervalSince1970)): HTTP 429")
        #expect(try await read("e") == "transient: Failed to fetch Codex usage: fetch failed")
        #expect(try await read("f") == "transient: HTTP 502")
        #expect(try await read("g") == "transient: Timed out")
        await #expect(throws: ProxyAccessError.offline("Network unavailable")) { _ = try await read("h") }
    }

    @Test func listingStatusMapping() async throws {
        func list(_ reply: StubHTTP.Reply) async -> ProxyAccessError? {
            do { _ = try await adapter(StubHTTP { _ in reply }).listAccounts(); return nil } catch { return error as? ProxyAccessError }
        }
        #expect(await list((404, Data(), [:])) == .failed("9Router API not found at this URL"))
        #expect(await list((500, Data(), [:])) == .failed("HTTP 500"))
        #expect(await list((200, Data("<html>".utf8), [:])) == .failed("Unreadable /api/providers response"))
    }
}

@Suite("CLIProxyAPI adapter")
struct CLIProxyAPIAdapterTests {
    func adapter(_ http: StubHTTP, key: String? = "mgmt", config: ProxyConfig = cpaConfig) -> CLIProxyAPIAdapter {
        CLIProxyAPIAdapter(config: config, managementKey: key, http: http, now: { productionNow })
    }

    @Test func readsEveryAccountThroughApiCall() async throws {
        let cpa = adapter(cpaTestbed())
        let accounts = try await cpa.listAccounts()
        #expect(accounts.map(\.id) == ["0000000000000001", "0000000000000002"])

        let codex = try #require(accounts.first { $0.provider == .codex })
        #expect(codex.label == "account3@example.com")
        #expect(codex.identity == "00000000-0000-4000-8000-000000000006")
        #expect(codex.metadataPlan == "free")
        #expect(codex.locator == .cpa(authIndex: "0000000000000002", codexAccountID: "00000000-0000-4000-8000-000000000006", projectID: nil))
        #expect(codex.proxyNote == nil && !codex.coolingDown && codex.cooldownUntil == nil)
        #expect(summary(try await cpa.readUsage(codex, force: false)) == "windows 30-day=0 plan=free credits=0")

        let ag = try #require(accounts.first { $0.provider == .antigravity })
        #expect(ag.locator == .cpa(authIndex: "0000000000000001", codexAccountID: nil, projectID: "sample-project-2"))
        #expect(ag.identity == "account4@example.com")
        #expect(summary(try await cpa.readUsage(ag, force: false)) == "windows Gemini · Weekly=100, Claude & GPT · Weekly=100 plan=nil")
    }

    @Test func requestWhitelist() async throws {
        let http = cpaTestbed()
        let cpa = adapter(http)
        for account in try await cpa.listAccounts() { _ = try await cpa.readUsage(account, force: true) }
        let allowed = Set([UpstreamClients.codexUsage(accountID: nil).url, UpstreamClients.claudeUsage.url]
                          + UpstreamClients.antigravityQuotaSummary(project: "p").map(\.url))
        for request in http.requests {
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer mgmt")
            switch (request.httpMethod ?? "GET", request.path) {
            case ("GET", "/v0/management/auth-files"): break
            case ("POST", "/v0/management/api-call"): #expect(allowed.contains(request.jsonBody["url"] as? String ?? ""))
            default: Issue.record("unexpected request \(request.httpMethod ?? "") \(request.path)")
            }
        }
        #expect(http.requests.count == 3)
    }

    @Test func codexCallCarriesAccountIdAndTokenPlaceholder() async throws {
        let http = cpaTestbed()
        let cpa = adapter(http)
        for account in try await cpa.listAccounts() { _ = try await cpa.readUsage(account, force: false) }
        let call = try #require(http.requests.first { ($0.jsonBody["url"] as? String)?.contains("wham") == true })
        let header = try #require(call.jsonBody["header"] as? [String: String])
        #expect(header["Authorization"] == "Bearer $TOKEN$")
        #expect(header["Chatgpt-Account-Id"] == "00000000-0000-4000-8000-000000000006")
        #expect(call.jsonBody["auth_index"] as? String == "0000000000000002")
    }

    @Test func wrongKeyIsUnauthorized() async {
        await #expect(throws: ProxyAccessError.unauthorized("Management key rejected")) { try await adapter(cpaTestbed(), key: "nope").listAccounts() }
    }

    @Test func missingKeySendsNothing() async {
        let http = cpaTestbed()
        await #expect(throws: ProxyAccessError.missingCredential) { try await adapter(http, key: "").listAccounts() }
        #expect(http.requests.isEmpty)
    }

    @Test func listingStatusMapping() async {
        await #expect(throws: ProxyAccessError.failed("Management API not found — enable remote management")) {
            try await adapter(StubHTTP { _ in (404, Data(), [:]) }).listAccounts()
        }
        await #expect(throws: ProxyAccessError.failed("HTTP 500")) { try await adapter(StubHTTP { _ in (500, Data(), [:]) }).listAccounts() }
        await #expect(throws: ProxyAccessError.failed("Unreadable auth-files response")) {
            try await adapter(StubHTTP { _ in (200, Data("[]".utf8), [:]) }).listAccounts()
        }
    }

    func upstream(_ status: Int, header: String = "{}") -> StubHTTP {
        StubHTTP { req in
            if req.path == "/v0/management/auth-files" { return (200, Fixture.data("cpa_auth_files"), [:]) }
            return (200, Data(#"{"status_code":\#(status),"header":\#(header),"body":"{\"error\":\"x\"}"}"#.utf8), [:])
        }
    }

    func codexReading(_ http: StubHTTP) async throws -> String {
        let cpa = adapter(http)
        let codex = try #require(try await cpa.listAccounts().first { $0.provider == .codex })
        return summary(try await cpa.readUsage(codex, force: false))
    }

    @Test func upstreamStatusMapping() async throws {
        #expect(try await codexReading(upstream(401)) == "credentialRejected: Upstream rejected the account token (401)")
        #expect(try await codexReading(upstream(403)) == "transient: Upstream HTTP 403")
        #expect(try await codexReading(upstream(503)) == "transient: Upstream HTTP 503")
        #expect(try await codexReading(upstream(429, header: #"{"retry-after":["60"]}"#))
                == "rateLimited(\(productionNow.addingTimeInterval(60).timeIntervalSince1970)): Rate limited by upstream (429)")
        #expect(try await codexReading(upstream(429)) == "rateLimited(nil): Rate limited by upstream (429)")
    }

    @Test func apiCallItselfRejectedIsUnauthorized() async throws {
        let http = StubHTTP { req in
            req.path == "/v0/management/auth-files" ? (200, Fixture.data("cpa_auth_files"), [:]) : (403, Data(), [:])
        }
        await #expect(throws: ProxyAccessError.unauthorized("Management key rejected")) { _ = try await codexReading(http) }
        let broken = StubHTTP { req in
            req.path == "/v0/management/auth-files" ? (200, Fixture.data("cpa_auth_files"), [:]) : (502, Data(), [:])
        }
        #expect(try await codexReading(broken) == "transient: api-call HTTP 502")
    }

    @Test func antigravityFallsBackToTheProductionEndpoint() async throws {
        let http = StubHTTP { req in
            if req.path == "/v0/management/auth-files" { return (200, Fixture.data("cpa_auth_files"), [:]) }
            let url = req.jsonBody["url"] as? String ?? ""
            if url.contains("daily-cloudcode") { return (200, Data(#"{"status_code":503,"header":{},"body":""}"#.utf8), [:]) }
            return (200, Fixture.data("cpa_apicall_antigravity_1"), [:])
        }
        let cpa = adapter(http)
        let ag = try #require(try await cpa.listAccounts().first { $0.provider == .antigravity })
        #expect(summary(try await cpa.readUsage(ag, force: false)).hasPrefix("windows Gemini · Weekly=100"))
        #expect(http.requests.compactMap { $0.jsonBody["url"] as? String }
                == UpstreamClients.antigravityQuotaSummary(project: "sample-project-2").map(\.url))
    }

    @Test func accountsWithoutAReadablePath() async throws {
        let cpa = adapter(cpaTestbed())
        let noProject = AccountDescriptor(id: "1", provider: .antigravity, label: "x", locator: .cpa(authIndex: "1", codexAccountID: nil, projectID: nil))
        #expect(summary(try await cpa.readUsage(noProject, force: false)) == "unavailable(6h): Account has no project id")
        let qoder = AccountDescriptor(id: "2", provider: Provider(rawValue: "qoder"), label: "x", locator: .cpa(authIndex: "2", codexAccountID: nil, projectID: nil))
        #expect(summary(try await cpa.readUsage(qoder, force: false)) == "unavailable(6h): Motas cannot read Qoder quota through CLIProxyAPI yet")
    }

    @Test func descriptorCooldownAndNote() throws {
        let file: [String: Any] = [
            "auth_index": "9", "provider": "codex", "email": "A@Example.com", "status": "error", "status_message": "token expired",
            "unavailable": true, "account_id": "acct",
            "cooldowns": [["until": "2026-11-02T17:00:00Z"], ["reset_at": "2026-11-02T18:00:00Z"], ["until": "2026-11-01T00:00:00Z"]],
        ]
        let account = CLIProxyAPIAdapter.descriptor(file, now: productionNow)
        #expect(account.cooldownUntil == Dates.iso("2026-11-02T18:00:00Z"))
        #expect(account.coolingDown)
        #expect(account.proxyNote == ProxyNote(message: "token expired"))
        #expect(account.identity == "a@example.com")
        #expect(account.locator == .cpa(authIndex: "9", codexAccountID: "acct", projectID: nil))

        let quiet = CLIProxyAPIAdapter.descriptor(["auth_index": "8", "provider": "codex", "status": "active", "status_message": "ok"], now: productionNow)
        #expect(quiet.proxyNote == nil && !quiet.coolingDown && quiet.cooldownUntil == nil)
    }

    @Test func plainHTTPToAPublicHostIsRefused() async throws {
        let http = cpaTestbed()
        let config = ProxyConfig(name: "public", kind: .cliProxyAPI, baseURL: URL(string: "http://cpa.example.com:8317")!)
        await #expect(throws: ProxyAccessError.failed("Refusing to send the secret over plain HTTP to cpa.example.com")) {
            try await adapter(http, config: config).listAccounts()
        }
        #expect(http.requests.isEmpty)
    }
}

@Suite("HTTP rules")
struct HTTPRulesTests {
    @Test func privateHosts() {
        for host in ["localhost", "nas.local", "127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.20", "100.64.0.1",
                     "100.127.255.255", "169.254.1.1", "::1", "[::1]", "fd00::1", "fe80::1"] {
            #expect(isPrivateHost(host), "\(host)")
        }
        for host in ["router.example.com", "8.8.8.8", "172.32.0.1", "100.128.0.1", "192.169.0.1", "2001:db8::1", "local", "example.local.com"] {
            #expect(!isPrivateHost(host), "\(host)")
        }
    }

    @Test func plainHTTPOnlyMattersForPublicHosts() throws {
        try checkPlainHTTP(URL(string: "https://router.example.com")!)
        try checkPlainHTTP(URL(string: "http://192.168.1.20:8317")!)
        #expect(throws: ProxyAccessError.self) { try checkPlainHTTP(URL(string: "http://8.8.8.8")!) }
    }

    @Test func sessionRules() async throws {
        let client = URLSessionHTTPClient()
        let configuration = client.session.configuration
        #expect(configuration.timeoutIntervalForRequest == 15)
        #expect(configuration.timeoutIntervalForResource == 20)
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.urlCache == nil)

        let delegate = try #require(client.session.delegate as? RefuseRedirects)
        let task = client.session.dataTask(with: URL(string: "https://router.example.com")!)   // never resumed
        let response = HTTPURLResponse(url: URL(string: "https://router.example.com")!, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://elsewhere.example.net"])!
        let next = await delegate.urlSession(client.session, task: task, willPerformHTTPRedirection: response,
                                             newRequest: URLRequest(url: URL(string: "https://elsewhere.example.net")!))
        #expect(next == nil)
        #expect(redirected(response) == .failed("Redirected to elsewhere.example.net — use the final URL in Settings"))
    }

    @Test func retryAfter() {
        #expect(Dates.retryAfter("120", now: productionNow) == productionNow.addingTimeInterval(120))
        #expect(Dates.retryAfter("Mon, 02 Nov 2026 16:20:30 GMT", now: productionNow) == productionNow.addingTimeInterval(600))
        #expect(Dates.retryAfter("soon", now: productionNow) == nil)
        #expect(Dates.retryAfter(nil, now: productionNow) == nil)
    }
}

/// A thread-safe integer a stub can read while a test changes it.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int
    init(_ value: Int = 0) { _value = value }
    var value: Int {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
