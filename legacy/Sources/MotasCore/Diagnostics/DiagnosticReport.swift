import Foundation

public struct DiagnosticConnectorConfiguration: Codable, Sendable, Equatable {
    public let id: String
    public let enabled: Bool
    public let endpointLabel: String?
    public let statusFileConfigured: Bool
    public let enabledSource: String

    public init(
        id: String,
        enabled: Bool,
        endpointLabel: String? = nil,
        statusFileConfigured: Bool = false,
        enabledSource: String
    ) {
        self.id = id
        self.enabled = enabled
        self.endpointLabel = endpointLabel
        self.statusFileConfigured = statusFileConfigured
        self.enabledSource = enabledSource
    }
}

public struct DiagnosticReportInput: Sendable {
    public let generatedAt: Date
    public let appVersion: String
    public let snapshot: StatusSnapshot
    public let history: StatusHistory
    public let configurations: [DiagnosticConnectorConfiguration]
    public let issues: [String]

    public init(
        generatedAt: Date,
        appVersion: String,
        snapshot: StatusSnapshot,
        history: StatusHistory,
        configurations: [DiagnosticConnectorConfiguration] = [],
        issues: [String] = []
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.snapshot = snapshot
        self.history = history
        self.configurations = configurations
        self.issues = issues
    }
}

public struct DiagnosticReport: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String
    public let readiness: HistoryReadinessSummary
    public let providers: [HistoryProviderSummary]
    public let proxies: [HistoryProxySummary]
    public let configurations: [DiagnosticConnectorConfiguration]
    public let history: [StatusHistoryEntry]
    public let issues: [String]

    public init(input: DiagnosticReportInput) {
        schemaVersion = 1
        generatedAt = input.generatedAt
        appVersion = input.appVersion
        readiness = HistoryReadinessSummary(from: input.snapshot.readiness)
        providers = input.snapshot.providers.map(HistoryProviderSummary.init)
        proxies = input.snapshot.proxies.map(HistoryProxySummary.init)
        configurations = input.configurations.sorted { $0.id < $1.id }
        history = input.history.entries
        issues = input.issues
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

public enum DiagnosticExportFormat: Sendable, Equatable {
    case json
    case markdown
}

public struct DiagnosticReportBuilder: Sendable {
    public init() {}

    public func build(_ input: DiagnosticReportInput) -> DiagnosticReport {
        DiagnosticReport(input: input)
    }

    public func export(
        _ report: DiagnosticReport,
        format: DiagnosticExportFormat
    ) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            return try encoder.encode(report)
        case .markdown:
            return Data(markdown(report).utf8)
        }
    }

    private func markdown(_ report: DiagnosticReport) -> String {
        var lines = [
            "# Motas diagnostics",
            "",
            "- Schema: \(report.schemaVersion)",
            "- App version: \(report.appVersion)",
            "- Generated: \(report.generatedAt.formatted(.iso8601))",
            "- Readiness: \(report.readiness.state.rawValue)",
            "- Readiness title: \(report.readiness.title)",
            "- Primary source: \(report.readiness.primarySourceID ?? "none")",
            "",
            "## Providers",
            "",
        ]

        if report.providers.isEmpty {
            lines.append("No provider data.")
        } else {
            for provider in report.providers {
                lines.append(
                    "- \(provider.name) [\(provider.id)]: \(provider.health.rawValue), \(provider.quality.rawValue)"
                )
            }
        }

        lines += ["", "## Proxies", ""]
        if report.proxies.isEmpty {
            lines.append("No proxy data.")
        } else {
            for proxy in report.proxies {
                lines.append(
                    "- \(proxy.name) [\(proxy.id)]: \(proxy.health.rawValue), \(proxy.quality.rawValue), accounts=\(proxy.accountCount)"
                )
            }
        }

        lines += ["", "## Configuration", ""]
        if report.configurations.isEmpty {
            lines.append("No connector configuration summary.")
        } else {
            for configuration in report.configurations {
                let endpoint = configuration.endpointLabel ?? "none"
                lines.append(
                    "- \(configuration.id): enabled=\(configuration.enabled), endpoint=\(endpoint), source=\(configuration.enabledSource)"
                )
            }
        }

        lines += ["", "## Recent history", "", "entries=\(report.history.count)"]
        if !report.issues.isEmpty {
            lines += ["", "## Issues", ""]
            lines += report.issues.map { "- \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
