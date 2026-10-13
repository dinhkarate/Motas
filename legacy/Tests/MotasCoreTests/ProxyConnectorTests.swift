import Foundation
import Testing

@testable import MotasCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

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
        ]
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

@Test("9Router usage maps quotas with epoch-seconds reset")
func nineRouterUsageWindows() async throws {
    let providers: [String: Any] = [
        "connections": [
            [
                "id": "conn-1",
                "provider": "claude",
                "name": "Claude Main",
                "isActive": true,
                "testStatus": "success",
                "authType": "oauth",
            ]
        ]
    ]
    let usage: [String: Any] = [
        "plan": "Claude Code",
        "quotas": [
            "session (5h)": ["remainingPercentage": 13, "resetAt": "1789000000"]
        ],
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["ok": true])),
        .success(jsonResponse(providers)),
        .success(jsonResponse(usage)),
    ])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128")!,
            dashboardToken: "session-secret",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    let account = try #require(status.accounts.first)
    #expect(account.quotaWindows.count == 1)
    #expect(account.quotaWindows[0].name == "session (5h)")
    #expect(account.quotaWindows[0].remainingFraction == 0.13)
    #expect(account.quotaWindows[0].resetsAt == Date(timeIntervalSince1970: 1_789_000_000))
    #expect(status.quotaWindows.count == 1)
    #expect(status.observation.quality == .fresh)
    let requests = await transport.capturedRequests()
    #expect(requests[2].url?.path == "/api/usage/conn-1")
    #expect(requests[2].url?.query == nil)
}

@Test("9Router unlimited quota yields no windows")
func nineRouterUnlimitedSkipped() async throws {
    let providers: [String: Any] = [
        "connections": [
            [
                "id": "conn-1", "provider": "claude", "isActive": true, "testStatus": "success",
                "authType": "oauth",
            ]
        ]
    ]
    let usage: [String: Any] = ["quotas": ["x": ["unlimited": true]]]
    let transport = QueueTransport([
        .success(jsonResponse(["ok": true])),
        .success(jsonResponse(providers)),
        .success(jsonResponse(usage)),
    ])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128")!,
            dashboardToken: "session-secret",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    #expect(status.accounts.first?.quotaWindows.isEmpty == true)
    #expect(status.quotaWindows.isEmpty)
}

@Test("9Router message-only usage degrades to partial, stays healthy")
func nineRouterMessageOnlyPartial() async throws {
    let providers: [String: Any] = [
        "connections": [
            [
                "id": "conn-1", "provider": "claude", "name": "Main", "isActive": true,
                "testStatus": "success", "authType": "oauth",
            ]
        ]
    ]
    let usage: [String: Any] = ["message": "Claude connected. Unable to fetch usage: upstream busy"]
    let transport = QueueTransport([
        .success(jsonResponse(["ok": true])),
        .success(jsonResponse(providers)),
        .success(jsonResponse(usage)),
    ])
    let connector = NineRouterConnector(
        configuration: NineRouterConfiguration(
            baseURL: URL(string: "http://localhost:20128")!,
            dashboardToken: "session-secret",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    #expect(status.accounts.first?.health == .healthy)
    #expect(status.observation.quality == .partial)
    #expect(status.quotaWindows.isEmpty)
}

@Test("CLIProxyAPI model discovery returns healthy partial without management key")
func cliProxyModelsOnly() async throws {
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "gpt-5"], ["id": "claude-sonnet"]]]))
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
        ]
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

@Test("CLIProxyAPI anonymous accounts receive stable deterministic IDs")
func cliProxyAnonymousAccountIDs() async {
    let payload: [String: Any] = [
        "files": [
            ["provider": "claude", "status": "active"],
            ["provider": "claude", "status": "active"],
        ]
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "model"]]])),
        .success(jsonResponse(payload)),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317")!,
            managementKey: "management-key"
        ),
        transport: transport,
        now: { connectorDate }
    )

    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }

    #expect(status.accounts.map(\.id) == ["anonymous-0-claude", "anonymous-1-claude"])
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
    #expect(
        ReadinessEngine().evaluate(providers: [], proxies: [status], at: connectorDate).state
            == .unknown)
}

@Test("CLIProxyAPI quota fetch maps buckets to account and route windows")
func cliProxyQuotaWindows() async throws {
    let authFiles: [String: Any] = [
        "files": [
            ["auth_index": "a1", "name": "a1.json", "provider": "claude", "status": "active"]
        ]
    ]
    let quota: [String: Any] = [
        "subscription": ["plan": "Pro"],
        "groups": [
            [
                "displayName": "Claude",
                "buckets": [
                    [
                        "window": "5-hour",
                        "remainingFraction": 0.34,
                        "resetTime": "2026-09-14T12:00:00Z",
                    ]
                ],
            ]
        ],
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "m"]]])),
        .success(jsonResponse(authFiles)),
        .success(jsonResponse(quota)),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317")!,
            managementKey: "management-key",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    let account = try #require(status.accounts.first)
    #expect(account.quotaWindows.count == 1)
    #expect(account.quotaWindows[0].name == "Claude · 5-hour")
    #expect(account.quotaWindows[0].remainingFraction == 0.34)
    #expect(account.quotaWindows[0].resetsAt != nil)
    #expect(status.quotaWindows.count == 1)
    #expect(status.quotaWindows[0].remainingFraction == 0.34)
    #expect(status.observation.quality == .fresh)
    #expect(account.label.contains("Pro"))
}

@Test("CLIProxyAPI route window keeps the best account fraction")
func cliProxyQuotaPoolBest() async throws {
    func quotaBody(_ fraction: Double) -> [String: Any] {
        [
            "groups": [
                [
                    "displayName": "Claude",
                    "buckets": [["window": "5-hour", "remainingFraction": fraction]],
                ]
            ]
        ]
    }
    let authFiles: [String: Any] = [
        "files": [
            ["auth_index": "a1", "name": "a1.json", "provider": "claude", "status": "active"],
            ["auth_index": "a2", "name": "a2.json", "provider": "claude", "status": "active"],
        ]
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "m"]]])),
        .success(jsonResponse(authFiles)),
        .success(jsonResponse(quotaBody(0.10))),
        .success(jsonResponse(quotaBody(0.80))),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317")!,
            managementKey: "management-key",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    #expect(status.quotaWindows.count == 1)
    #expect(status.quotaWindows[0].remainingFraction == 0.80)
}

@Test("CLIProxyAPI 501 marks unsupported and suppresses the second probe")
func cliProxyQuotaUnsupportedCached() async throws {
    let authFiles: [String: Any] = [
        "files": [["auth_index": "a1", "name": "a1.json", "provider": "codex", "status": "active"]]
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "m"]]])),
        .success(jsonResponse(authFiles)),
        .success(
            jsonResponse(["error": "no quota provider available for credential"], status: 501)),
        .success(jsonResponse(["data": [["id": "m"]]])),
        .success(jsonResponse(authFiles)),
    ])
    let cache = QuotaProbeCache()
    let config = CLIProxyAPIConfiguration(
        baseURL: URL(string: "http://localhost:8317")!,
        managementKey: "management-key",
        quotaCache: cache
    )
    let first = CLIProxyAPIConnector(
        configuration: config, transport: transport, now: { connectorDate })
    guard case .proxy(let firstStatus) = await first.refresh(trigger: .scheduled) else {
        Issue.record("Expected proxy result")
        return
    }
    #expect(firstStatus.accounts.first?.quotaWindows.isEmpty == true)
    let second = CLIProxyAPIConnector(
        configuration: config, transport: transport, now: { connectorDate })
    guard case .proxy = await second.refresh(trigger: .manual) else {
        Issue.record("Expected proxy result")
        return
    }
    let requests = await transport.capturedRequests()
    let fetches = requests.filter { $0.url?.path == "/v0/management/quota/fetch" }
    #expect(fetches.count == 1)
}

@Test("CLIProxyAPI null remainingFraction produces no window")
func cliProxyQuotaNullSkipped() async throws {
    let authFiles: [String: Any] = [
        "files": [
            ["auth_index": "a1", "name": "a1.json", "provider": "claude", "status": "active"]
        ]
    ]
    let quota: [String: Any] = [
        "groups": [
            [
                "displayName": "Claude",
                "buckets": [["window": "5-hour", "remainingFraction": NSNull()]],
            ]
        ]
    ]
    let transport = QueueTransport([
        .success(jsonResponse(["data": [["id": "m"]]])),
        .success(jsonResponse(authFiles)),
        .success(jsonResponse(quota)),
    ])
    let connector = CLIProxyAPIConnector(
        configuration: CLIProxyAPIConfiguration(
            baseURL: URL(string: "http://localhost:8317")!,
            managementKey: "management-key",
            quotaCache: QuotaProbeCache()
        ),
        transport: transport,
        now: { connectorDate }
    )
    guard case .proxy(let status) = await connector.refresh() else {
        Issue.record("Expected proxy result")
        return
    }
    #expect(status.accounts.first?.quotaWindows.isEmpty == true)
    #expect(status.quotaWindows.isEmpty)
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
