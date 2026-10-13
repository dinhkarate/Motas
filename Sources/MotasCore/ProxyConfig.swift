import Foundation

/// A configured remote proxy. Secrets are not stored here; see `SecretStore`.
public struct ProxyConfig: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: ProxyKind
    public var baseURL: URL
    public var isEnabled: Bool

    public init(id: UUID = UUID(), name: String, kind: ProxyKind, baseURL: URL, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.isEnabled = isEnabled
    }
}

public protocol ProxyAdapter: Sendable {
    func fetch() async -> ProxySnapshot
}

public enum ProxyAdapters {
    public static func make(_ config: ProxyConfig, secret: String?, http: any HTTPClient) -> any ProxyAdapter {
        switch config.kind {
        case .cliProxyAPI: CLIProxyAPIAdapter(config: config, managementKey: secret, http: http)
        case .nineRouter: NineRouterAdapter(config: config, password: secret, http: http)
        }
    }
}

/// Runs `transform` over `items` with at most `limit` in flight, preserving order.
func boundedMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        func addNext() {
            guard next < items.count else { return }
            let index = next, item = items[index]
            next += 1
            group.addTask { (index, await transform(item)) }
        }
        for _ in 0..<min(limit, items.count) { addNext() }
        while let (index, value) = await group.next() {
            results[index] = value
            addNext()
        }
        return results.map { $0! }
    }
}

extension URL {
    func appendingAPIPath(_ path: String) -> URL {
        var base = absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + path)!
    }
}

func describe(_ error: Error) -> String {
    if let url = error as? URLError {
        switch url.code {
        case .timedOut: return "Timed out"
        case .cannotConnectToHost: return "Connection refused"
        case .cannotFindHost, .dnsLookupFailed: return "Host not found"
        case .notConnectedToInternet, .networkConnectionLost: return "Network unavailable"
        case .secureConnectionFailed, .serverCertificateUntrusted: return "TLS error"
        default: return url.localizedDescription
        }
    }
    return error.localizedDescription
}
