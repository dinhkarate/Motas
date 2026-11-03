import Foundation

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Every proxy request goes through one ephemeral session: 15 s without data
/// or 20 s in total per request, no cookie storage (adapters set the cookie
/// header) and no cache. Redirects are refused, so a 3xx comes back as the
/// response and a secret header never follows it to another origin.
public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }
}

final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Adapters never follow a 3xx: the user should save the final URL instead.
func redirected(_ response: HTTPURLResponse) -> ProxyAccessError {
    let target = response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: response.url) }
    return .failed("Redirected to \(target?.absoluteURL.host ?? "another URL") — use the final URL in Settings")
}

/// Throws before a secret would cross the network in clear text: plain HTTP
/// is allowed only for loopback, `*.local`, RFC 1918, 100.64.0.0/10,
/// link-local and IPv6 ULA hosts.
func checkPlainHTTP(_ url: URL) throws {
    guard url.scheme?.lowercased() == "http", !isPrivateHost(url.host ?? "") else { return }
    throw ProxyAccessError.failed("Refusing to send the secret over plain HTTP to \(url.host ?? url.absoluteString)")
}

func isPrivateHost(_ host: String) -> Bool {
    let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".local") { return true }
    var v4 = in_addr()
    if inet_pton(AF_INET, host, &v4) == 1 {
        let ip = UInt32(bigEndian: v4.s_addr)
        func within(_ network: UInt32, _ bits: UInt32) -> Bool { ip >> (32 - bits) == network >> (32 - bits) }
        return within(0x7F00_0000, 8) || within(0x0A00_0000, 8) || within(0xAC10_0000, 12) || within(0xC0A8_0000, 16)
            || within(0x6440_0000, 10) || within(0xA9FE_0000, 16)
    }
    var v6 = in6_addr()
    if inet_pton(AF_INET6, host, &v6) == 1 {
        let b = withUnsafeBytes(of: v6) { Array($0) }
        let loopback = b[0..<15].allSatisfy { $0 == 0 } && b[15] == 1
        return loopback || b[0] & 0xFE == 0xFC || (b[0] == 0xFE && b[1] & 0xC0 == 0x80)
    }
    return false
}

enum JSON {
    static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? {
        guard let s = self[key] as? String, !s.isEmpty else { return nil }
        return s
    }

    func double(_ key: String) -> Double? {
        switch self[key] {
        case let n as NSNumber: n.doubleValue
        case let s as String: Double(s)
        default: nil
        }
    }

    func int(_ key: String) -> Int? { double(key).flatMap { Int(exactly: $0.rounded(.towardZero)) } }
    func bool(_ key: String) -> Bool? { (self[key] as? NSNumber)?.boolValue }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func dicts(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }
}

enum Dates {
    nonisolated(unsafe) private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()
    private static let http: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    static func iso(_ s: String?) -> Date? {
        guard let s else { return nil }
        return fractional.date(from: s) ?? plain.date(from: s)
    }

    /// A `Retry-After` value: seconds or an HTTP date.
    static func retryAfter(_ value: String?, now: Date) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return TimeInterval(value).map { now.addingTimeInterval($0) } ?? http.date(from: value)
    }
}
