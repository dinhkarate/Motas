import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public init() {}

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let headers = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key).lowercased()] = String(describing: entry.value)
        }
        return HTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: headers,
            body: data
        )
    }
}

public enum EndpointNormalizer {
    public static func baseURL(from value: URL) -> URL {
        var components = URLComponents(url: value, resolvingAgainstBaseURL: false)
        var path = components?.path ?? ""
        for suffix in ["/v1", "/v0/management"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        components?.path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? value
    }

    public static func url(base: URL, path: String) -> URL? {
        let normalizedBase = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        return URL(string: normalizedBase + normalizedPath)
    }

    public static func redactedLabel(for url: URL) -> String {
        guard let host = url.host else { return "Local endpoint" }
        if let port = url.port {
            return "\(host):\(port)"
        }
        return host
    }
}
