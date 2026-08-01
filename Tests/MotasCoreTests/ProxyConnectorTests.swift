import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MotasCore

private let connectorDate = Date(timeIntervalSince1970: 1_750_000_000)

private actor QueueTransport: HTTPTransport {
    private var responses: [Result<HTTPResponse, Error>]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [Result<HTTPResponse, Error>]) {
        self.responses = responses
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        return try responses.removeFirst().get()
    }

    func capturedRequests() -> [URLRequest] {
        requests
    }
}

private func jsonResponse(_ object: Any, status: Int = 200) -> HTTPResponse {
    HTTPResponse(
        statusCode: status,
        headers: ["content-type": "application/json"],
        body: try! JSONSerialization.data(withJSONObject: object)
    )
}

@Test("9Router public health returns healthy partial without dashboard access")
func nineRouterPublicHealth() async throws {
    let transport = QueueTransport([.success(jsonResponse(["ok": true]))])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128")!
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.health == .healthy)
    #expect(status.observation.quality == .partial)
    #expect(status.route?.fallbackAvailable == nil)
    #expect(status.accounts.isEmpty)
}

@Test("9Router maps protected provider connections without exposing email")
func nineRouterProtectedAccounts() async throws {
    let providers: [String: Any] = [
        "connections": [
            [
                "id": "claude-1",
                "provider": "claude",
                "name": "Claude Main",
                "email": "owner@example.com",
                "isActive": true,
                "testStatus": "success",
            ],
            [
                "id": "codex-1",
                "provider": "codex",
                "email": "other@example.com",
                "isActive": true,
                "testStatus": "error",
            ],
        ],
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["ok": true])),
        .success(jsonResponse(providers)),
    ])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128/v1")!,
            dashboardToken: "session-secret"
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.accounts.count == 2)
    #expect(status.accounts[0].health == .healthy)
    #expect(status.accounts[1].health == .degraded)
    #expect(!status.accounts.map(\.label).contains("other@example.com"))

    let requests = await transport.capturedRequests()
    #expect(requests.count == 2)
    #expect(requests[1].value(forHTTPHeaderField: "Cookie") == "auth_token=session-secret")
    #expect(requests[1].url?.path == "/api/providers")
}

@Test("9Router unreachable becomes proxy down input")
func nineRouterUnreachable() async {
    let transport = QueueTransport([.failure(URLError(.cannotConnectToHost))])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128")!,
            isRequiredRoute: true
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    let assessment = ReadinessEngine().evaluate(providers: [], proxies: [status], at: connectorDate)

    #expect(status.health == .unreachable)
    #expect(assessment.state == .proxyDown)
}

@Test("CLIProxyAPI model discovery returns healthy partial without management key")
func cliProxyModelsOnly() async throws {
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "gpt-5"], ["id": "claude-sonnet"]]])),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317/v1")!
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.health == .healthy)
    #expect(status.observation.quality == .partial)
    #expect(status.observation.message?.contains("2 discoverable models") == true)
    #expect(status.route?.fallbackAvailable == nil)
}

@Test("CLIProxyAPI maps auth-file health and uses management bearer key")
func cliProxyAuthFiles() async throws {
    let authFiles: [String: Any] = [
        "files": [
            [
                "id": "codex-file",
                "auth_index": "idx-1",
                "name": "codex.json",
                "provider": "codex",
                "email": "owner@example.com",
                "status": "active",
                "disabled": false,
                "unavailable": false,
                "success": 10,
                "failed": 1,
            ],
            [
                "id": "claude-file",
                "auth_index": "idx-2",
                "name": "claude.json",
                "provider": "claude",
                "status": "error",
                "status_message": "cooldown",
                "disabled": false,
                "unavailable": true,
            ],
        ],
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "gpt-5"]]])),
        .success(jsonResponse(authFiles)),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317/v0/management")!,
            proxyAPIKey: "proxy-key",
            managementKey: "management-key"
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.accounts.count == 2)
    #expect(status.accounts.first(where: { $0.id == "idx-1" })?.health == .healthy)
    #expect(status.accounts.first(where: { $0.id == "idx-2" })?.health == .degraded)
    #expect(status.route?.fallbackAvailable == true)
    #expect(!status.accounts.map(\.label).contains("owner@example.com"))

    let requests = await transport.capturedRequests()
    #expect(requests[0].url?.path == "/v1/models")
    #expect(requests[0].value(forHTTPHeaderField: "Authorization") == "Bearer proxy-key")
    #expect(requests[1].url?.path == "/v0/management/auth-files")
    #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer management-key")
}

@Test("CLIProxyAPI rejected proxy key is unauthorized, not unreachable")
func cliProxyUnauthorized() async {
    let transport = QueueTransport([.success(jsonResponse(["error": "unauthorized"], status: 401))])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317")!,
            proxyAPIKey: "bad-key"
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.health == .unauthorized)
    #expect(ReadinessEngine().evaluate(providers: [], proxies: [status], at: connectorDate).state == .unknown)
}

@Test("Endpoint normalizer removes known API suffixes")
func endpointNormalization() {
    #expect(
        EndpointNormalizer.baseURL(from: URL(string: "http://localhost:8317/v1")!).absoluteString
            == "http://localhost:8317"
    )
    #expect(
        EndpointNormalizer.baseURL(
            from: URL(string: "http://localhost:8317/v0/management")!
        ).absoluteString == "http://localhost:8317"
    )
}
