import Foundation
import Security

public struct MotasSettings: Codable, Sendable, Hashable {
    public var proxies: [ProxyConfig]
    /// Seconds between automatic refreshes; clamped to 60…3600.
    public var refreshInterval: TimeInterval
    /// Pool reserve below which the menu bar turns amber and a notification fires.
    public var lowReserveThreshold: Double
    public var notificationsEnabled: Bool

    public init(proxies: [ProxyConfig] = [], refreshInterval: TimeInterval = 300, lowReserveThreshold: Double = 0.2, notificationsEnabled: Bool = true) {
        self.proxies = proxies
        self.refreshInterval = refreshInterval
        self.lowReserveThreshold = lowReserveThreshold
        self.notificationsEnabled = notificationsEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = MotasSettings()
        proxies = try c.decodeIfPresent([ProxyConfig].self, forKey: .proxies) ?? d.proxies
        refreshInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? d.refreshInterval
        lowReserveThreshold = try c.decodeIfPresent(Double.self, forKey: .lowReserveThreshold) ?? d.lowReserveThreshold
        notificationsEnabled = try c.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? d.notificationsEnabled
    }

    public var clampedRefreshInterval: TimeInterval { min(max(refreshInterval, 60), 3600) }
}

/// JSON file persistence. A corrupt file is reported, never silently replaced.
public struct SettingsStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Motas", isDirectory: true)
            .appendingPathComponent("settings.json")
    }

    public func load() throws -> MotasSettings {
        guard FileManager.default.fileExists(atPath: url.path) else { return MotasSettings() }
        return try JSONDecoder().decode(MotasSettings.self, from: Data(contentsOf: url))
    }

    public func save(_ settings: MotasSettings) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: url, options: .atomic)
    }
}

public protocol SecretStore: Sendable {
    func secret(for proxy: UUID) throws -> String?
    func setSecret(_ value: String?, for proxy: UUID) throws
}

public struct KeychainSecretStore: SecretStore {
    let service: String

    public init(service: String = "dev.motas.proxy") { self.service = service }

    private func query(_ proxy: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: proxy.uuidString]
    }

    public func secret(for proxy: UUID) throws -> String? {
        var q = query(proxy)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func setSecret(_ value: String?, for proxy: UUID) throws {
        let deleteStatus = SecItemDelete(query(proxy) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError(status: deleteStatus) }
        guard let value, !value.isEmpty else { return }
        var q = query(proxy)
        q[kSecValueData as String] = Data(value.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String]

    public init(_ values: [UUID: String] = [:]) { self.values = values }

    public func secret(for proxy: UUID) throws -> String? { lock.withLock { values[proxy] } }
    public func setSecret(_ value: String?, for proxy: UUID) throws {
        lock.withLock { values[proxy] = (value?.isEmpty == false) ? value : nil }
    }
}
