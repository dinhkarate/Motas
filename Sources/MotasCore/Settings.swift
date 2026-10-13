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
    /// With `interactive == false` this must never block on a system prompt:
    /// it throws `SecretStoreError.needsApproval` instead.
    func secret(for proxy: UUID, interactive: Bool) throws -> String?
    func setSecret(_ value: String?, for proxy: UUID) throws
    /// Whether a secret exists, without reading it (never prompts).
    func hasSecret(for proxy: UUID) -> Bool
}

extension SecretStore {
    public func secret(for proxy: UUID) throws -> String? { try secret(for: proxy, interactive: false) }
}

public enum SecretStoreError: Error, Equatable {
    /// macOS wants the user to allow Motas to read the item (first launch after
    /// an update of an ad-hoc signed build, or an item created by another tool).
    case needsApproval
}

/// Login-keychain store. Successful reads are cached for the process
/// lifetime, so a user approval prompt happens at most once per launch.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    let service: String
    private let lock = NSLock()
    private var cache: [UUID: String] = [:]

    public init(service: String = "dev.motas.proxy") { self.service = service }

    private func query(_ proxy: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: proxy.uuidString]
    }

    public func secret(for proxy: UUID, interactive: Bool) throws -> String? {
        try lock.withLock {
            if let cached = cache[proxy] { return cached }
            var q = query(proxy)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            // The file-based login keychain ignores kSecUseAuthenticationUIFail;
            // this (process-wide, hence the lock) is what stops SecurityAgent
            // from blocking a background refresh.
            SecKeychainSetUserInteractionAllowed(interactive)
            let status = SecItemCopyMatching(q as CFDictionary, &out)
            SecKeychainSetUserInteractionAllowed(true)
            switch status {
            case errSecSuccess:
                guard let data = out as? Data, let value = String(data: data, encoding: .utf8) else { return nil }
                cache[proxy] = value
                return value
            case errSecItemNotFound:
                return nil
            case errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled:
                throw SecretStoreError.needsApproval
            default:
                throw KeychainError(status: status)
            }
        }
    }

    public func setSecret(_ value: String?, for proxy: UUID) throws {
        try lock.withLock {
            cache[proxy] = nil
            let deleteStatus = SecItemDelete(query(proxy) as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError(status: deleteStatus) }
            guard let value, !value.isEmpty else { return }
            var q = query(proxy)
            q[kSecValueData as String] = Data(value.utf8)
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let status = SecItemAdd(q as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
            cache[proxy] = value
        }
    }

    public func hasSecret(for proxy: UUID) -> Bool {
        lock.withLock {
            if cache[proxy] != nil { return true }
            var q = query(proxy)
            q[kSecReturnAttributes as String] = true
            SecKeychainSetUserInteractionAllowed(false)
            defer { SecKeychainSetUserInteractionAllowed(true) }
            return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
        }
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
    /// Simulates items macOS will only release after an interactive approval.
    private var needingApproval: Set<UUID>

    public init(_ values: [UUID: String] = [:], needingApproval: Set<UUID> = []) {
        self.values = values
        self.needingApproval = needingApproval
    }

    public func secret(for proxy: UUID, interactive: Bool) throws -> String? {
        try lock.withLock {
            if needingApproval.contains(proxy) {
                guard interactive else { throw SecretStoreError.needsApproval }
                needingApproval.remove(proxy)
            }
            return values[proxy]
        }
    }

    public func setSecret(_ value: String?, for proxy: UUID) throws {
        lock.withLock {
            needingApproval.remove(proxy)
            values[proxy] = (value?.isEmpty == false) ? value : nil
        }
    }

    public func hasSecret(for proxy: UUID) -> Bool { lock.withLock { values[proxy] != nil } }
}
