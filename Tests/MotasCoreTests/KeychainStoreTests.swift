import Foundation
import Security
import Testing
@testable import MotasCore

/// The one Keychain item and the 0.2 items, counting every call. A locked
/// read needs approval: without interaction it throws `.needsApproval`, and an
/// interactive one approves, after waiting at the gate when there is one.
final class FakeKeychain: KeychainBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _item: Data?
    private var _legacy: [UUID: String]
    private var locked: Bool
    private var legacyLocked: Bool
    private var _calls: [String] = []
    private var _deleteFailures: [UUID: OSStatus] = [:]
    private var _declinesLegacy = false
    private let writeFailure: OSStatus?
    /// Interactive reads of the item wait here until `release()` opens it for good.
    private let gate: DispatchSemaphore?
    /// Signalled when an interactive read of the item starts.
    let entered = DispatchSemaphore(value: 0)

    init(item: Data? = nil, legacy: [UUID: String] = [:], locked: Bool = false, legacyLocked: Bool = false, gated: Bool = false,
         writeFailure: OSStatus? = nil) {
        _item = item
        _legacy = legacy
        self.locked = locked
        self.legacyLocked = legacyLocked
        gate = gated ? DispatchSemaphore(value: 0) : nil
        self.writeFailure = writeFailure
    }

    var item: Data? {
        get { lock.withLock { _item } }
        set { lock.withLock { _item = newValue } }
    }

    var legacy: [UUID: String] { lock.withLock { _legacy } }
    var calls: [String] { lock.withLock { _calls } }

    /// What `deleteLegacy` fails with, per item. `errSecInvalidOwnerEdit`
    /// leaves the item scrubbed, as a newer build's delete of an older build's item does.
    var deleteFailures: [UUID: OSStatus] {
        get { lock.withLock { _deleteFailures } }
        set { lock.withLock { _deleteFailures = newValue } }
    }

    /// While set, the user declines the 0.2 items' prompt.
    var declinesLegacy: Bool {
        get { lock.withLock { _declinesLegacy } }
        set { lock.withLock { _declinesLegacy = newValue } }
    }

    func release() { gate?.signal() }

    func read(interactive: Bool) throws -> Data? {
        record("read(interactive: \(interactive))")
        if interactive {
            entered.signal()
            gate?.wait()
            gate?.signal()    // open from now on
        }
        return try lock.withLock {
            if interactive { locked = false } else if locked { throw SecretStoreError.needsApproval }
            return _item
        }
    }

    func write(_ data: Data) throws {
        record("write")
        if let writeFailure { throw KeychainError(status: writeFailure) }
        item = data
    }

    func readLegacy(interactive: Bool) throws -> [UUID: String] {
        record("readLegacy(interactive: \(interactive))")
        return try lock.withLock {
            if interactive, _declinesLegacy { throw SecretStoreError.needsApproval }
            if interactive { legacyLocked = false } else if legacyLocked { throw SecretStoreError.needsApproval }
            return _legacy
        }
    }

    func deleteLegacy(_ id: UUID) throws {
        record("deleteLegacy")
        try lock.withLock {
            switch _deleteFailures[id] {
            case nil: _legacy[id] = nil
            case .some(errSecInvalidOwnerEdit):
                _legacy[id] = ""
                throw KeychainError(status: errSecInvalidOwnerEdit)
            case .some(let status): throw KeychainError(status: status)
            }
        }
    }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }
}

/// An item as the store writes it.
func itemData(_ secrets: [UUID: String]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["v": 1, "secrets": Dictionary(uniqueKeysWithValues: secrets.map { ($0.key.uuidString, $0.value) })])
}

/// The secrets in an item, by uuid string.
func storedSecrets(in item: Data?) -> [String: String]? {
    item.flatMap { JSON.object($0)?["secrets"] as? [String: String] }
}

@Suite("Keychain store", .timeLimit(.minutes(1)))
struct KeychainStoreTests {
    let a = UUID(), b = UUID(), c = UUID()

    func store(_ keychain: FakeKeychain, preferences: UIPreferences = temporaryPreferences()) -> KeychainSecretStore {
        KeychainSecretStore(backend: keychain, preferences: preferences)
    }

    @Test func theItemRoundTrips() async throws {
        let keychain = FakeKeychain()
        let first = store(keychain)
        try await first.setSecret("token-a", for: a)
        try await first.setSecret("token-b", for: b)
        let item = try #require(keychain.item)
        #expect(JSON.object(item)?["v"] as? Int == 1)
        #expect(storedSecrets(in: item) == [a.uuidString: "token-a", b.uuidString: "token-b"])

        let relaunched = store(keychain)
        #expect(try relaunched.secret(for: a) == "token-a")
        try await relaunched.setSecret(nil, for: a)
        #expect(storedSecrets(in: keychain.item) == [b.uuidString: "token-b"])
        #expect(try relaunched.secret(for: a) == nil && relaunched.secret(for: b) == "token-b")
    }

    @Test func aMissingItemIsCachedAsNoSecrets() throws {
        let keychain = FakeKeychain()
        let store = store(keychain)
        #expect(try store.secret(for: a) == nil)
        #expect(store.presence() == .known([]))
        #expect(try store.secret(for: b) == nil)
        #expect(keychain.calls == ["read(interactive: false)"])
    }

    @Test func presenceAnswersFromTheCacheOnly() throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]))
        let store = store(keychain)
        #expect(store.presence() == .locked)
        #expect(keychain.calls.isEmpty)
        #expect(try store.secret(for: b) == nil)    // one read caches every proxy's secret
        #expect(store.presence() == .known([a]))
        #expect(keychain.calls.count == 1)
    }

    @Test func aLockedItemNeedsApprovalAndReadsNeverPrompt() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]), locked: true)
        let store = store(keychain)
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: a) }
        #expect(store.presence() == .locked)
        try await store.approve()
        #expect(try store.secret(for: a) == "token-a")
        #expect(keychain.calls == ["read(interactive: false)", "read(interactive: true)"])
    }

    @Test func aReadDuringABlockedApprovalNeedsApprovalAtOnce() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]), locked: true, gated: true)
        let store = store(keychain)
        let approval = Task { try await store.approve() }
        await wait(for: keychain.entered)
        let clock = ContinuousClock()
        let start = clock.now
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: a) }
        #expect(start.duration(to: clock.now) < .milliseconds(300))
        keychain.release()
        try await approval.value
        #expect(try store.secret(for: a) == "token-a")
    }

    @Test func aWriteDuringAPendingApprovalWaitsForIt() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]), locked: true, gated: true)
        let store = store(keychain)
        let approval = Task { try await store.approve() }
        await wait(for: keychain.entered)
        let write = Task { try await store.setSecret("token-b", for: b) }
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: a) }    // the approval holds `io`
        #expect(!keychain.calls.contains("write"))
        keychain.release()
        try await approval.value
        try await write.value
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "token-a", b.uuidString: "token-b"])
        #expect(store.presence() == .known([a, b]))
        #expect(keychain.calls == ["read(interactive: true)", "read(interactive: false)", "write"])
    }

    @Test func writesMergeIntoTheItemReadFresh() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]))
        let store = store(keychain)
        #expect(try store.secret(for: a) == "token-a")
        keychain.item = itemData([a: "token-a", b: "token-b"])    // the CLI added b meanwhile
        try await store.setSecret("token-c", for: c)
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "token-a", b.uuidString: "token-b", c.uuidString: "token-c"])
        #expect(store.presence() == .known([a, b, c]))
    }

    @Test func aWriteAsksOnlyWhenItMust() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]), locked: true)
        try await store(keychain).setSecret("token-b", for: b)
        #expect(keychain.calls == ["read(interactive: false)", "read(interactive: true)", "write"])
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "token-a", b.uuidString: "token-b"])
    }

    @Test func anItemThatIsNotAVersion1BlobIsNeverOverwritten() async throws {
        let keychain = FakeKeychain(item: Data(#"{"v":2,"secrets":{}}"#.utf8))
        let store = store(keychain)
        #expect(throws: KeychainError.self) { try store.secret(for: a) }
        await #expect(throws: KeychainError.self) { try await store.setSecret("token-a", for: a) }
        #expect(!keychain.calls.contains("write"))
    }

    @Test func aFailedWriteThrowsAndCachesNothing() async throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]), writeFailure: errSecIO)
        let store = store(keychain)
        await #expect(throws: KeychainError.self) { try await store.setSecret("token-b", for: b) }
        #expect(store.presence() == .locked)
        #expect(try store.secret(for: b) == nil && store.presence() == .known([a]))
    }

    @Test func invalidateDropsTheCache() throws {
        let keychain = FakeKeychain(item: itemData([a: "one"]))
        let store = store(keychain)
        #expect(try store.secret(for: a) == "one")
        keychain.item = itemData([a: "two"])    // changed by the CLI
        #expect(try store.secret(for: a) == "one")
        store.invalidate()
        #expect(store.presence() == .locked)
        #expect(try store.secret(for: a) == "two")
        #expect(keychain.calls == ["read(interactive: false)", "read(interactive: false)"])
    }

    /// Empty values are skipped, keys the item has are kept, and every 0.2 item is deleted.
    @Test func approvalMigratesTheLegacyItemsOnce() async throws {
        let keychain = FakeKeychain(item: itemData([c: "token-c"]), legacy: [a: "legacy-a", b: "", c: "legacy-c"], legacyLocked: true)
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        let store = store(keychain, preferences: preferences)
        // Pending, so offered as an approval; nothing is cached or moved.
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: c) }
        #expect(store.presence() == .locked)

        try await store.approve()
        #expect(store.presence() == .known([a, c]))
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "legacy-a", c.uuidString: "token-c"])
        #expect(keychain.legacy.isEmpty)
        #expect(preferences.legacyKeychainMigrated)

        let before = keychain.calls.count
        try await store.approve()
        #expect(Array(keychain.calls.dropFirst(before)) == ["read(interactive: true)"])
    }

    @Test func legacyItemsAnOlderBuildOwnsAreLeftScrubbed() async throws {
        let keychain = FakeKeychain(legacy: [a: "legacy-a"])
        keychain.deleteFailures = [a: errSecInvalidOwnerEdit]
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        try await store(keychain, preferences: preferences).approve()
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "legacy-a"])
        #expect(keychain.legacy == [a: ""])
        #expect(preferences.legacyKeychainMigrated)
        // A scrubbed item is nothing to migrate, even if the flag were lost.
        #expect(try store(keychain, preferences: temporaryPreferences(legacyKeychainMigrated: false)).secret(for: a) == "legacy-a")
    }

    @Test func theFlagWaitsForAFullPass() async throws {
        let keychain = FakeKeychain(legacy: [a: "legacy-a", b: "legacy-b"])
        keychain.deleteFailures = [b: errSecIO]
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        let store = store(keychain, preferences: preferences)
        await #expect(throws: KeychainError.self) { try await store.approve() }
        #expect(!preferences.legacyKeychainMigrated)
        #expect(keychain.legacy[b] == "legacy-b")
        #expect(try store.secret(for: a) == "legacy-a")    // the item was read and merged all the same

        keychain.deleteFailures = [:]
        try await store.approve()
        #expect(preferences.legacyKeychainMigrated && keychain.legacy.isEmpty)
        #expect(storedSecrets(in: keychain.item) == [a.uuidString: "legacy-a", b.uuidString: "legacy-b"])
    }

    @Test func theMigrationRunsOnlyInsideApprove() async throws {
        let keychain = FakeKeychain(legacy: [a: "legacy-a"])
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        let store = store(keychain, preferences: preferences)
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: a) }
        try await store.setSecret("token-b", for: b)
        #expect(storedSecrets(in: keychain.item) == [b.uuidString: "token-b"])
        #expect(keychain.legacy == [a: "legacy-a"])
        #expect(!keychain.calls.contains("deleteLegacy") && !keychain.calls.contains("readLegacy(interactive: true)"))
        #expect(!preferences.legacyKeychainMigrated)
        // The write cached nothing, so reads keep offering the approval that migrates.
        #expect(store.presence() == .locked)
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: b) }
        try await store.approve()
        #expect(store.presence() == .known([a, b]) && preferences.legacyKeychainMigrated)
    }

    /// A declined prompt for the 0.2 items caches nothing, so Allow… stays on
    /// offer, and the next approval migrates them.
    @Test func aDeclinedMigrationKeepsOfferingApproval() async throws {
        let keychain = FakeKeychain(item: itemData([c: "token-c"]), legacy: [a: "legacy-a"], legacyLocked: true)
        keychain.declinesLegacy = true
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        let store = store(keychain, preferences: preferences)
        await #expect(throws: SecretStoreError.needsApproval) { try await store.approve() }
        #expect(store.presence() == .locked)
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: c) }
        #expect(!preferences.legacyKeychainMigrated && keychain.legacy == [a: "legacy-a"])

        keychain.declinesLegacy = false
        try await store.approve()
        #expect(store.presence() == .known([a, c]) && preferences.legacyKeychainMigrated)
    }

    @Test func withoutLegacyItemsNothingIsPending() throws {
        let keychain = FakeKeychain(item: itemData([a: "token-a"]))
        let preferences = temporaryPreferences(legacyKeychainMigrated: false)
        #expect(try store(keychain, preferences: preferences).secret(for: a) == "token-a")
        #expect(keychain.calls == ["read(interactive: false)", "readLegacy(interactive: false)"])
        #expect(!preferences.legacyKeychainMigrated)    // only an approval sets it
    }

    @Test func theInMemoryStoreLocksLikeTheItem() async throws {
        let store = InMemorySecretStore([a: "token-a"], needingApproval: true)
        #expect(throws: SecretStoreError.needsApproval) { try store.secret(for: a) }
        #expect(store.presence() == .locked)
        try await store.approve()
        #expect(try store.secret(for: a) == "token-a" && store.presence() == .known([a]))
        store.needingApproval = true
        try await store.setSecret("", for: a)    // a write approves; empty removes
        #expect(store.presence() == .known([]))
    }
}
