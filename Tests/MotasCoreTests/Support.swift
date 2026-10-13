import Foundation
@testable import MotasCore

enum Fixture {
    static func data(_ name: String) -> Data {
        let url = Bundle.module.url(forResource: "Fixtures/live/\(name)", withExtension: "json")!
        return try! Data(contentsOf: url)
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

let cpaConfig = ProxyConfig(name: "Testbed CPA", kind: .cliProxyAPI, baseURL: URL(string: "http://cpa.test:8317")!)
let nineConfig = ProxyConfig(name: "Testbed 9Router", kind: .nineRouter, baseURL: URL(string: "http://9r.test:20128/")!)

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

/// Serves the captured 9Router testbed (login required).
func nineTestbed(password: String = "pw") -> StubHTTP {
    StubHTTP { req in
        if req.path == "/api/auth/login" {
            guard req.jsonBody["password"] as? String == password else {
                return (401, Data(#"{"error":"Invalid password"}"#.utf8), [:])
            }
            return (200, Data(#"{"success":true,"mustChangePassword":false}"#.utf8),
                    ["Set-Cookie": "auth_token=jwt123; Path=/; HttpOnly; SameSite=Lax"])
        }
        guard req.value(forHTTPHeaderField: "Cookie") == "auth_token=jwt123" else {
            return (401, Fixture.data("9r_unauth_providers"), [:])
        }
        if req.path == "/api/providers" { return (200, Fixture.data("9r_providers"), [:]) }
        if req.path.hasPrefix("/api/usage/") {
            let providers = try JSONSerialization.jsonObject(with: Fixture.data("9r_providers")) as! [String: Any]
            let id = String(req.path.dropFirst("/api/usage/".count))
            let conn = (providers["connections"] as! [[String: Any]]).first { $0["id"] as? String == id }
            switch conn?["provider"] as? String {
            case "codex": return (200, Fixture.data("9r_usage_codex"), [:])
            case "gemini-cli": return (200, Fixture.data("9r_usage_gemini-cli"), [:])
            default: return (404, Data(#"{"error":"Connection not found"}"#.utf8), [:])
            }
        }
        return (404, Data(), [:])
    }
}
