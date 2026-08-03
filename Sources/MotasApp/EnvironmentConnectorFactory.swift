import Foundation
import MotasCore

enum EnvironmentConnectorFactory {
    static func connectors(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any StatusConnector] {
        var connectors: [any StatusConnector] = []

        if environment["MOTAS_CLAUDE_CODE_ENABLED"] == "1" {
            let defaultPath = NSString(
                string: "~/Library/Application Support/Motas/claude-code-status.json"
            ).expandingTildeInPath
            let statusPath = environment["MOTAS_CLAUDE_STATUS_FILE"] ?? defaultPath
            connectors.append(
                ClaudeCodeConnector(
                    configuration: ClaudeCodeConfiguration(
                        statusFileURL: URL(fileURLWithPath: statusPath)
                    )
                )
            )
        }

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
            let hasPrimaryProxy = environment["MOTAS_9ROUTER_URL"] != nil
            connectors.append(
                CLIProxyAPIConnector(
                    configuration: CLIProxyAPIConfiguration(
                        baseURL: url,
                        role: hasPrimaryProxy ? .fallback : .primary,
                        isRequiredRoute: !hasPrimaryProxy,
                        proxyAPIKey: environment["MOTAS_CLIPROXYAPI_KEY"],
                        managementKey: environment["MOTAS_CLIPROXYAPI_MANAGEMENT_KEY"]
                    )
                )
            )
        }

        return connectors
    }
}
