import Foundation

public enum ConnectorSecretStoreError: Error, Equatable {
    case unavailable(String)
}

/// Stores opaque connector secrets (proxy/management keys).
///
/// Implementations must never expose secret values in error text. The protocol
/// stays in `MotasCore` so tests can use in-memory fakes; the concrete macOS
/// Keychain implementation lives in `MotasApp`.
public protocol ConnectorSecretStore: Sendable {
    func value(for key: ConnectorSecretKey) throws -> String?
    func set(_ value: String, for key: ConnectorSecretKey) throws
    func removeValue(for key: ConnectorSecretKey) throws
    func containsValue(for key: ConnectorSecretKey) throws -> Bool
}