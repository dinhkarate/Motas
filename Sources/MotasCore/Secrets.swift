import Foundation
import os
import Security

/// Which proxies have a secret, as far as the cache knows: `.locked` until
/// the Keychain item has been read.
public enum SecretPresence: Sendable, Equatable {
    case known(Set<UUID>)
    case locked

    /// Whether `id` has a secret; nil while locked.
    public func contains(_ id: UUID) -> Bool? {
        guard case .known(let ids) = self else { return nil }
        return ids.contains(id)
    }
}

public protocol SecretStore: Sendable {
    /// Never prompts: throws `SecretStoreError.needsApproval` when macOS wants
    /// the user to allow the read first.
    func secret(for id: UUID) throws -> String?
    /// From the cache only; never touches Keychain.
    func presence() -> SecretPresence
    /// The interactive read a user action allows; fills the cache.
    func approve() async throws
    /// Stores `value` for `id`; nil or empty removes it.
    func setSecret(_ value: String?, for id: UUID) async throws
    /// Drops the cache after an external change (the CLI).
    func invalidate()
}

public enum SecretStoreError: Error, Equatable {
    /// macOS wants the user to allow Motas to read the item (first launch after
    /// an update of an ad-hoc signed build, or an item created by another tool).
    case needsApproval
}

/// The Keychain calls `KeychainSecretStore` makes: `SystemKeychain`, or a fake in tests.
public protocol KeychainBackend: Sendable {
    /// The item's data; nil when there is none. When not interactive, throws
    /// `SecretStoreError.needsApproval` instead of prompting.
    func read(interactive: Bool) throws -> Data?
    /// Updates the item, or adds it when missing.
    func write(_ data: Data) throws
    /// The 0.2 items (service `dev.motas.proxy`, account = proxy uuid), by proxy.
    func readLegacy(interactive: Bool) throws -> [UUID: String]
    /// Scrubs a 0.2 item to empty data, then deletes it.
    func deleteLegacy(_ id: UUID) throws
}

/// Every proxy secret in one login-keychain item, so a new build asks for
/// approval once, not once per proxy.
///
/// Background reads never prompt and never wait more than 0.2 s; `approve` and
/// `setSecret` run on one serial queue, so a prompt waiting for the user blocks
/// no caller's thread. `io` is taken once per public call, always before
/// `cache`, and the private `…Locked` helpers do the work under it.
public final class KeychainSecretStore: SecretStore, @unchecked Sendable {
    private let backend: any KeychainBackend
    /// Holds `legacyKeychainMigrated`.
    private let preferences: UIPreferences
    /// Guards every backend call and the process-wide user-interaction switch.
    private let io = NSLock()
    /// The item as last read or written; nil until then.
    private let cache = OSAllocatedUnfairLock<Blob?>(initialState: nil)
    private let queue = DispatchQueue(label: "dev.motas.keychain")

    public init(backend: any KeychainBackend = SystemKeychain(), preferences: UIPreferences = UIPreferences()) {
        self.backend = backend
        self.preferences = preferences
    }

    public func secret(for id: UUID) throws -> String? {
        if let blob = cache.withLock({ $0 }) { return blob.secrets[id] }
        // A pending approval holds `io`: give up quickly rather than wait for the user.
        guard io.lock(before: Date(timeIntervalSinceNow: 0.2)) else { throw SecretStoreError.needsApproval }
        defer { io.unlock() }
        return try loadLocked().secrets[id]
    }

    public func presence() -> SecretPresence {
        cache.withLock { $0.map { .known(Set($0.secrets.keys)) } ?? .locked }
    }

    /// Reads the item with a prompt if macOS wants one, then migrates the 0.2
    /// items once. The cache is filled even when the migration fails; its error
    /// is thrown, and the next approval tries it again.
    public func approve() async throws {
        try await onQueue { [self] in
            try io.withLock {
                var blob = try Blob(backend.read(interactive: true))
                var migration: (any Error)?
                if !preferences.legacyKeychainMigrated {
                    do { try migrateLocked(&blob) } catch { migration = error }
                }
                cache.withLock { [blob] in $0 = blob }
                if let migration { throw migration }
            }
        }
    }

    /// Merges into the item as it is now (read fresh, never from the cache, so
    /// what the CLI or the app wrote meanwhile is kept), then caches the result,
    /// unless 0.2 items still wait for `approve`: then reads keep offering it.
    public func setSecret(_ value: String?, for id: UUID) async throws {
        try await onQueue { [self] in
            try io.withLock {
                let fresh = try readFreshLocked()
                var blob = fresh
                blob.secrets[id] = value?.isEmpty == false ? value : nil
                if blob != fresh { try backend.write(blob.data()) }
                let pending = !preferences.legacyKeychainMigrated && legacyPendingLocked()
                cache.withLock { [blob] in $0 = pending ? nil : blob }
            }
        }
    }

    public func invalidate() {
        cache.withLock { $0 = nil }
    }

    /// A non-interactive read that fills the cache. While 0.2 items wait for
    /// the migration, which only `approve` runs, it throws `.needsApproval`
    /// and caches nothing, so the user is offered Allow….
    private func loadLocked() throws -> Blob {
        if let blob = cache.withLock({ $0 }) { return blob }    // filled while waiting for `io`
        let blob = try Blob(backend.read(interactive: false))
        if !preferences.legacyKeychainMigrated, legacyPendingLocked() { throw SecretStoreError.needsApproval }
        cache.withLock { $0 = blob }
        return blob
    }

    /// 0.2 items hold secrets to migrate, or need approval to tell. A failure
    /// to ask never blocks the item itself.
    private func legacyPendingLocked() -> Bool {
        do {
            return try backend.readLegacy(interactive: false).values.contains { !$0.isEmpty }
        } catch SecretStoreError.needsApproval {
            return true
        } catch {
            return false
        }
    }

    /// The item as it is now: without a prompt when possible.
    private func readFreshLocked() throws -> Blob {
        do {
            return try Blob(backend.read(interactive: false))
        } catch SecretStoreError.needsApproval {
            return try Blob(backend.read(interactive: true))
        }
    }

    /// Moves the 0.2 secrets into `blob`, skipping empty values and never
    /// overriding a key it has, then scrubs and deletes every 0.2 item. The
    /// flag is set only after this full pass.
    private func migrateLocked(_ blob: inout Blob) throws {
        let legacy = try backend.readLegacy(interactive: true)
        var merged = blob
        for (id, value) in legacy where !value.isEmpty && merged.secrets[id] == nil { merged.secrets[id] = value }
        if merged != blob {
            try backend.write(merged.data())
            blob = merged
        }
        for id in legacy.keys {
            do {
                try backend.deleteLegacy(id)
            } catch let error as KeychainError where error.status == errSecInvalidOwnerEdit {
                // Scrubbed already: a newer build may empty an older build's item but not delete it.
            }
        }
        preferences.legacyKeychainMigrated = true
    }

    private func onQueue(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// The item's data: `{"v":1,"secrets":{"<proxy uuid>":"<secret>"}}`.
    struct Blob: Equatable, Sendable {
        var secrets: [UUID: String] = [:]

        /// No data (no item) is the empty blob. Anything but a v1 blob throws,
        /// so a newer or foreign item is never overwritten.
        init(_ data: Data?) throws {
            guard let data else { return }
            guard let file = try? JSONDecoder().decode(File.self, from: data), file.v == 1 else {
                throw KeychainError(status: errSecDecode)
            }
            for (key, value) in file.secrets where !value.isEmpty {
                if let id = UUID(uuidString: key) { secrets[id] = value }
            }
        }

        func data() throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return try encoder.encode(File(v: 1, secrets: Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.uuidString, $0.value) })))
        }

        private struct File: Codable {
            var v: Int
            var secrets: [String: String]
        }
    }
}

/// The login keychain. A non-interactive call switches user interaction off
/// around it: the file-based login keychain ignores `kSecUseAuthenticationUIFail`
/// and would block on SecurityAgent. The switch is process-wide, which is why
/// `KeychainSecretStore` makes every call under its `io` lock.
public struct SystemKeychain: KeychainBackend {
    public init() {}

    public func read(interactive: Bool) throws -> Data? {
        try Self.data(Self.item, interactive: interactive)
    }

    /// Updates in place: a newer (ad-hoc, differently signed) build may update
    /// an older build's item silently, but never delete it.
    public func write(_ data: Data) throws {
        var status = SecItemUpdate(Self.item as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var query = Self.item
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            status = SecItemAdd(query as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func readLegacy(interactive: Bool) throws -> [UUID: String] {
        // Attributes only: listing never needs the items' approval.
        var query = Self.legacy(nil)
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        var out: CFTypeRef?
        let status = Self.call(interactive: interactive) { SecItemCopyMatching(query as CFDictionary, &out) }
        guard status != errSecItemNotFound else { return [:] }
        guard status == errSecSuccess else { throw Self.error(status) }
        var values: [UUID: String] = [:]
        for attributes in out as? [[String: Any]] ?? [] {
            guard let id = (attributes[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) else { continue }
            values[id] = try Self.data(Self.legacy(id), interactive: interactive).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
        return values
    }

    /// Scrubs before deleting, because the delete fails with
    /// `errSecInvalidOwnerEdit` when an older build created the item.
    public func deleteLegacy(_ id: UUID) throws {
        let query = Self.legacy(id) as CFDictionary
        let scrubbed = SecItemUpdate(query, [kSecValueData as String: Data()] as CFDictionary)
        guard scrubbed == errSecSuccess || scrubbed == errSecItemNotFound else { throw KeychainError(status: scrubbed) }
        let deleted = SecItemDelete(query)
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw KeychainError(status: deleted) }
    }

    private static var item: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.motas", kSecAttrAccount as String: "credentials"]
    }

    /// One 0.2 item, or all of them for a nil id.
    private static func legacy(_ id: UUID?) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "dev.motas.proxy"]
        query[kSecAttrAccount as String] = id?.uuidString
        return query
    }

    /// One item's data; nil when it does not exist.
    private static func data(_ query: [String: Any], interactive: Bool) throws -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = call(interactive: interactive) { SecItemCopyMatching(query as CFDictionary, &out) }
        switch status {
        case errSecSuccess: return out as? Data ?? Data()
        case errSecItemNotFound: return nil
        default: throw error(status)
        }
    }

    private static func call(interactive: Bool, _ body: () -> OSStatus) -> OSStatus {
        SecKeychainSetUserInteractionAllowed(interactive)
        defer { SecKeychainSetUserInteractionAllowed(true) }
        return body()
    }

    /// The item is there, but macOS wants the user to allow this build (or the user declined).
    private static func error(_ status: OSStatus) -> any Error {
        [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
            ? SecretStoreError.needsApproval : KeychainError(status: status)
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var description: String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// Secrets in memory, for tests and motas-render. With `needingApproval` on,
/// reads throw `.needsApproval` and presence is `.locked` until `approve()` or
/// a write, like the Keychain item after an update.
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: String]
    private var _needingApproval: Bool

    public init(_ values: [UUID: String] = [:], needingApproval: Bool = false) {
        self.values = values
        _needingApproval = needingApproval
    }

    public var needingApproval: Bool {
        get { lock.withLock { _needingApproval } }
        set { lock.withLock { _needingApproval = newValue } }
    }

    public func secret(for id: UUID) throws -> String? {
        try lock.withLock {
            if _needingApproval { throw SecretStoreError.needsApproval }
            return values[id]
        }
    }

    public func presence() -> SecretPresence {
        lock.withLock { _needingApproval ? .locked : .known(Set(values.keys)) }
    }

    public func approve() async throws {
        needingApproval = false
    }

    public func setSecret(_ value: String?, for id: UUID) async throws {
        lock.withLock {
            _needingApproval = false
            values[id] = value?.isEmpty == false ? value : nil
        }
    }

    public func invalidate() {}
}
