import Foundation
import MotasCore

enum EnvironmentConnectorFactory {
    static func connectors(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any StatusConnector] {
        var connectors: [any StatusConnector] = []

        if let rawURL = environment["MOTAS_9ROUTER_URL"],
           let url = URL(string: rawURL)
        {
            connectors.append(
                NineRouterConnector(
                    configuration: NineRouterConfiguration(
                        baseURL: url,
                        role: .primary,
                        isRequiredRoute: true,
                        dashboardToken: environment["MOTAS_9ROUTER_DASHBOARD_TOKEN"],
                        cliToken: environment["MOTAS_9ROUTER_CLI_TOKEN"]
                    )
                )
            )
        }

        if let rawURL = environment["MOTAS_CLIPROXYAPI_URL"],
           let url = URL(string: rawURL)
        {
            connectors.append(
                CLIProxyAPIConnector(
                    configuration: CLIProxyAPIConfiguration(
                        baseURL: url,
                        role: connectors.isEmpty ? .primary : .fallback,
                        isRequiredRoute: connectors.isEmpty,
                        proxyAPIKey: environment["MOTAS_CLIPROXYAPI_KEY"],
                        managementKey: environment["MOTAS_CLIPROXYAPI_MANAGEMENT_KEY"]
                    )
                )
            )
        }

        return connectors
    }
}
