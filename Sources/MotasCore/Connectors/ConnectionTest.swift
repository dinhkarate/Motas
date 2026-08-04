import Foundation

public enum ConnectionTestStatus: String, Codable, Sendable, Equatable {
    case healthy
    case degraded
    case unauthorized
    case unreachable
    case unsupported
    case unknown
}

public struct ConnectionTestResult: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let status: ConnectionTestStatus
    public let quality: DataQuality
    public let message: String?

    public init(
        id: String,
        name: String,
        status: ConnectionTestStatus,
        quality: DataQuality,
        message: String?
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.quality = quality
        self.message = message
    }
}

public struct ConnectorTestRunner: Sendable {
    public init() {}

    public func run(_ connectors: [any StatusConnector]) async -> [ConnectionTestResult] {
        await withTaskGroup(of: ConnectionTestResult.self) { group in
            for connector in connectors {
                group.addTask {
                    let result = await connector.refresh()
                    return Self.summary(for: connector, result: result)
                }
            }

            var results: [ConnectionTestResult] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.id < $1.id }
        }
    }

    private static func summary(
        for connector: any StatusConnector,
        result: ConnectorResult
    ) -> ConnectionTestResult {
        switch result {
        case .provider(let status):
            return ConnectionTestResult(
                id: connector.id,
                name: connector.displayName,
                status: map(status.health),
                quality: status.observation.quality,
                message: status.observation.message
            )
        case .proxy(let status):
            return ConnectionTestResult(
                id: connector.id,
                name: connector.displayName,
                status: map(status.health),
                quality: status.observation.quality,
                message: status.observation.message
            )
        }
    }

    private static func map(_ health: OperationalHealth) -> ConnectionTestStatus {
        switch health {
        case .healthy: .healthy
        case .degraded, .exhausted: .degraded
        case .unauthorized: .unauthorized
        case .unreachable: .unreachable
        case .unsupported: .unsupported
        case .unknown: .unknown
        }
    }
}
