import MotasCore

/// Ephemeral credentials used only by the Settings connection-test action.
/// Values are never persisted or published.
struct TransientSecretStore: ConnectorSecretStore, @unchecked Sendable {
    private let values: [ConnectorSecretKey: String]

    init(values: [ConnectorSecretKey: String]) {
        self.values = values.filter { !$0.value.isEmpty }
    }

    func value(for key: ConnectorSecretKey) throws -> String? {
        values[key]
    }

    func set(_ value: String, for key: ConnectorSecretKey) throws {}
    func removeValue(for key: ConnectorSecretKey) throws {}

    func containsValue(for key: ConnectorSecretKey) throws -> Bool {
        values[key] != nil
    }
}
