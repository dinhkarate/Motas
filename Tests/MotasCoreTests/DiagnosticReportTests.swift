import Foundation
import Testing
@testable import MotasCore

private let diagnosticDate = Date(timeIntervalSince1970: 1_750_000_000)

private func diagnosticSnapshot() -> StatusSnapshot {
    let provider = ProviderStatus(
        id: "claude-code-local",
        name: "Claude Code",
        role: .primary,
        health: .degraded,
        observation: Observation(
            checkedAt: diagnosticDate,
            quality: .partial,
            message: "token=should-not-export"
        ),
        quotaWindows: [
            QuotaWindow(
                id: "five-hour",
                name: "5-hour",
                unit: .percentage,
                remainingFraction: 0.2,
                resetsAt: diagnosticDate.addingTimeInterval(3600)
            ),
        ]
    )
    return StatusSnapshot(
        capturedAt: diagnosticDate,
        readiness: ReadinessAssessment(
            state: .caution,
            title: "Quota running low",
            explanation: "cookie=should-not-export",
            primarySourceID: provider.id,
            evaluatedAt: diagnosticDate
        ),
        providers: [provider],
        proxies: []
    )
}

private func diagnosticInput() -> DiagnosticReportInput {
    DiagnosticReportInput(
        generatedAt: diagnosticDate,
        appVersion: "test-build",
        snapshot: diagnosticSnapshot(),
        history: StatusHistory().appending(
            snapshot: diagnosticSnapshot(),
            at: diagnosticDate
        ),
        configurations: [
            DiagnosticConnectorConfiguration(
                id: "9router",
                enabled: true,
                endpointLabel: "localhost:20128",
                enabledSource: "Settings"
            ),
        ],
        issues: ["A sanitized issue"]
    )
}

@Test("Diagnostic JSON export is deterministic and sanitized")
func diagnosticJSONExport() throws {
    let builder = DiagnosticReportBuilder()
    let report = builder.build(diagnosticInput())
    let first = try builder.export(report, format: .json)
    let second = try builder.export(report, format: .json)

    #expect(first == second)
    let encoded = String(decoding: first, as: UTF8.self).lowercased()
    #expect(encoded.contains("localhost:20128"))
    #expect(!encoded.contains("token=should-not-export"))
    #expect(!encoded.contains("cookie=should-not-export"))
    #expect(!encoded.contains("authorization"))
}

@Test("Diagnostic Markdown export contains actionable normalized summaries")
func diagnosticMarkdownExport() throws {
    let builder = DiagnosticReportBuilder()
    let report = builder.build(diagnosticInput())
    let data = try builder.export(report, format: .markdown)
    let markdown = String(decoding: data, as: UTF8.self)

    #expect(markdown.contains("# Motas diagnostics"))
    #expect(markdown.contains("Claude Code"))
    #expect(markdown.contains("Quota running low"))
    #expect(markdown.contains("localhost:20128"))
    #expect(!markdown.contains("token=should-not-export"))
    #expect(!markdown.contains("cookie=should-not-export"))
}

@Test("Diagnostic report keeps stale and partial quality visible")
func diagnosticQualityPreserved() {
    let report = DiagnosticReportBuilder().build(diagnosticInput())
    #expect(report.providers.first?.quality == .partial)
    #expect(report.readiness.state == .caution)
    #expect(report.history.count == 1)
}
