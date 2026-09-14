import Foundation

public enum ConnectorResult: Sendable, Equatable {
    case provider(ProviderStatus)
    case proxy(ProxyStatus)
}

public protocol StatusConnector: Sendable {
    var id: String { get }
    var displayName: String { get }

    func refresh(trigger: RefreshTrigger) async -> ConnectorResult
}

public extension StatusConnector {
    func refresh() async -> ConnectorResult {
        await refresh(trigger: .scheduled)
    }
}

public struct StaticConnector: StatusConnector {
    public let id: String
    public let displayName: String
    private let result: ConnectorResult

    public init(id: String, displayName: String, result: ConnectorResult) {
        self.id = id
        self.displayName = displayName
        self.result = result
    }

    public func refresh(trigger: RefreshTrigger) async -> ConnectorResult {
        result
    }
}
