import Foundation
@testable import MotasCore

enum Fixture {
    /// `Fixtures/<dir>/<name>.json`: `live` (captured, sanitized), `synthetic`
    /// (9Router strings from its source) or `legacy` (written by Motas 0.2).
    static func url(_ name: String, dir: String = "live") -> URL {
        Bundle.module.url(forResource: "Fixtures/\(dir)/\(name)", withExtension: "json")!
    }

    static func data(_ name: String, dir: String = "live") -> Data {
        try! Data(contentsOf: url(name, dir: dir))
    }
}

/// HTTP stub: `handler` maps a request to (status, body, headers). Records
/// every request so tests can assert what Motas did and did not call.
final class StubHTTP: HTTPClient, @unchecked Sendable {
    typealias Reply = (status: Int, body: Data, headers: [String: String])
    private let lock = NSLock()
    private var _requests: [URLRequest] = []
    let handler: @Sendable (URLRequest) throws -> Reply

    init(_ handler: @escaping @Sendable (URLRequest) throws -> Reply) { self.handler = handler }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { _requests.append(request) }
        let reply = try handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (reply.body, response)
    }
}

extension URLRequest {
    var path: String { url!.path }
    var jsonBody: [String: Any] { (try? JSONSerialization.jsonObject(with: httpBody ?? Data())) as? [String: Any] ?? [:] }
}

/// `*.local` hosts: plain HTTP may carry a secret to them.
let cpaConfig = ProxyConfig(name: "Testbed CPA", kind: .cliProxyAPI, baseURL: URL(string: "http://cpa.local:8317")!)
let nineConfig = ProxyConfig(name: "Testbed 9Router", kind: .nineRouter, baseURL: URL(string: "http://9r.local:20128/")!, auth: .password)
let productionConfig = ProxyConfig(name: "Production 9Router", kind: .nineRouter, baseURL: URL(string: "https://router.example.com")!)
let productionToken = "0123456789abcdef"
/// When the production capture was taken: 2026-11-02T16:10:30Z.
let productionNow = Date(timeIntervalSince1970: 1_793_635_830)

/// Serves the captured CLIProxyAPI testbed.
func cpaTestbed(managementKey: String = "mgmt") -> StubHTTP {
    StubHTTP { req in
        guard req.value(forHTTPHeaderField: "Authorization") == "Bearer \(managementKey)" else {
            return (401, Data(#"{"error":"invalid management key"}"#.utf8), [:])
        }
        switch req.path {
        case "/v0/management/auth-files":
            return (200, Fixture.data("cpa_auth_files"), [:])
        case "/v0/management/api-call":
            let url = req.jsonBody["url"] as? String ?? ""
            if url.contains("wham/usage") { return (200, Fixture.data("cpa_apicall_codex_usage"), [:]) }
            if url.contains("retrieveUserQuotaSummary") { return (200, Fixture.data("cpa_apicall_antigravity_0"), [:]) }
            return (400, Data(), [:])
        case "/v0/management/quota/fetch":
            return (501, Fixture.data("cpa_quota_fetch_codex"), [:])
        default:
            return (404, Data(), [:])
        }
    }
}

/// What a refused CLI token throws.
let tokenRejected = ProxyAccessError.unauthorized(
    "CLI token rejected — machine-id or auth/cli-secret changed on the server; derive the token again")

/// The middleware's own 401: Motas's cookie or token was refused.
let sessionRejected: StubHTTP.Reply = (401, Fixture.data("9r_usage_session_unauthorized", dir: "synthetic"), [:])

func loginAccepted(cookie: String = "jwt123") -> StubHTTP.Reply {
    (200, Data(#"{"success":true,"mustChangePassword":false}"#.utf8), ["Set-Cookie": "auth_token=\(cookie); Path=/; HttpOnly; SameSite=Lax"])
}

/// A 9Router behind its middleware: `/api/*` takes one of `tokens` as
/// `x-9r-cli-token`, or the cookie from logging in with `password`.
func nineServer(tokens: Set<String> = [], password: String? = nil,
                routes: @escaping @Sendable (URLRequest) throws -> StubHTTP.Reply) -> StubHTTP {
    StubHTTP { req in
        if req.path == "/api/auth/login" {
            guard let password, req.jsonBody["password"] as? String == password else {
                return (401, Data(#"{"error":"Invalid password"}"#.utf8), [:])
            }
            return loginAccepted()
        }
        let token = req.value(forHTTPHeaderField: "x-9r-cli-token")
        let cookie = req.value(forHTTPHeaderField: "Cookie")
        guard token.map(tokens.contains) == true || (password != nil && cookie == "auth_token=jwt123") else { return sessionRejected }
        return try routes(req)
    }
}

/// Every production connection's usage reply, as captured.
let productionUsage: [String: StubHTTP.Reply] = {
    let byID = try! JSONSerialization.jsonObject(with: Fixture.data("9r_prod_usage_by_connection")) as! [String: [String: Any]]
    return byID.mapValues { ($0["status"] as! Int, try! JSONSerialization.data(withJSONObject: $0["body"]!), [:]) }
}()

/// The 2026-11-02 production capture (29 connections) without the credential check.
@Sendable func productionReply(_ req: URLRequest) -> StubHTTP.Reply {
    if req.path == "/api/providers" { return (200, Fixture.data("9r_prod_providers"), [:]) }
    if req.path.hasPrefix("/api/usage/"), let reply = productionUsage[String(req.path.dropFirst("/api/usage/".count))] {
        return reply
    }
    return (404, Fixture.data("9r_usage_not_found", dir: "synthetic"), [:])
}

/// The production 9Router: `9r_prod_providers.json` and every reply in
/// `9r_prod_usage_by_connection.json`, behind the middleware.
func nineProduction(tokens: Set<String> = [productionToken], password: String? = nil) -> StubHTTP {
    nineServer(tokens: tokens, password: password, routes: productionReply)
}

/// Provider of each connection in the 2026-10 testbed listing.
let testbedProviders: [String: String] = {
    let connections = JSON.object(Fixture.data("9r_providers"))?["connections"] as? [[String: Any]] ?? []
    return Dictionary(uniqueKeysWithValues: connections.map { ($0["id"] as! String, $0["provider"] as! String) })
}()

/// The captured 2026-10 testbed (a codex and a gemini-cli connection), password login.
func nineTestbed(password: String = "pw") -> StubHTTP {
    nineServer(password: password) { req in
        if req.path == "/api/providers" { return (200, Fixture.data("9r_providers"), [:]) }
        switch testbedProviders[String(req.path.dropFirst("/api/usage/".count))] {
        case "codex": return (200, Fixture.data("9r_usage_codex"), [:])
        case "gemini-cli": return (200, Fixture.data("9r_usage_gemini-cli"), [:])
        default: return (404, Fixture.data("9r_usage_not_found", dir: "synthetic"), [:])
        }
    }
}

/// A settable `now` for adapters, `ProxyState` and Monitor.
final class TestNow: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = productionNow) { self.value = value }

    var date: Date {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
    var function: @Sendable () -> Date { { self.date } }
}

/// A clock that moves only when told to, so budget tests never sleep.
final class TestClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Swift.Duration
        func advanced(by duration: Swift.Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Swift.Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Swift.Duration { .zero }
    func advance(by duration: Swift.Duration) { lock.withLock { _now = _now.advanced(by: duration) } }
    func sleep(until deadline: Instant, tolerance: Swift.Duration?) async throws {
        lock.withLock { _now = max(_now, deadline) }
    }
}

/// A secret store whose answers a test can change: values per proxy, one
/// error for every read (e.g. `SecretStoreError.needsApproval`), or one for
/// every write. Counts approvals and invalidations.
final class TestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String]
    private var _error: (any Error)?
    private var _writeError: (any Error)?
    private var _approvals = 0
    private var _invalidations = 0

    init(_ values: [UUID: String] = [:]) { self.values = values }

    var error: (any Error)? {
        get { lock.withLock { _error } }
        set { lock.withLock { _error = newValue } }
    }

    var writeError: (any Error)? {
        get { lock.withLock { _writeError } }
        set { lock.withLock { _writeError = newValue } }
    }

    var approvals: Int { lock.withLock { _approvals } }
    var invalidations: Int { lock.withLock { _invalidations } }

    func secret(for id: UUID) throws -> String? {
        try lock.withLock {
            if let _error { throw _error }
            return values[id]
        }
    }

    func presence() -> SecretPresence { lock.withLock { _error == nil ? .known(Set(values.keys)) : .locked } }

    func approve() async throws {
        lock.withLock {
            _approvals += 1
            _error = nil
        }
    }

    func setSecret(_ value: String?, for id: UUID) async throws {
        try lock.withLock {
            if let _writeError { throw _writeError }
            values[id] = value
        }
    }

    func invalidate() { lock.withLock { _invalidations += 1 } }
}

/// Waits for `semaphore` on a GCD thread, never blocking the cooperative pool.
func wait(for semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            semaphore.wait()
            continuation.resume()
        }
    }
}

/// UI preferences in a plist of their own (a suite named by a path), never the app's domain.
func temporaryPreferences(legacyKeychainMigrated: Bool = true) -> UIPreferences {
    let preferences = UIPreferences(defaults: UserDefaults(suiteName: tempURL("preferences").path)!)
    preferences.legacyKeychainMigrated = legacyKeychainMigrated
    return preferences
}

/// One line per reading, for table-driven expectations: limit windows as
/// "label=percent" (+ the count of other windows), else the kind and message.
func summary(_ reading: UsageReading) -> String {
    switch reading {
    case .windows(let windows, let plan, let extras):
        let limits = windows.filter { $0.role == .limit }.map { "\($0.label)=\(Int(($0.remainingFraction * 100).rounded()))" }
        var text = "windows " + limits.joined(separator: ", ")
        if limits.count < windows.count { text += " +\(windows.count - limits.count)" }
        text += " plan=\(plan ?? "nil")"
        if let credits = extras.resetCredits { text += " credits=\(credits)" }
        return text
    case .unavailable(let message, let recheck, let extras):
        return "unavailable(\(Int(recheck / 3600))h\(extras.quotaExceeded == true ? ", exceeded" : "")): \(message)"
    case .failed(let failure):
        switch failure.kind {
        case .transient: return "transient: \(failure.message)"
        case .rateLimited(let until): return "rateLimited(\(until.map { "\($0.timeIntervalSince1970)" } ?? "nil")): \(failure.message)"
        case .credentialRejected: return "credentialRejected: \(failure.message)"
        }
    }
}
