import Foundation
import Testing
@testable import MotasCore

private let claudeConnectorDate = Date(timeIntervalSince1970: 1_750_000_000)

@Test("Claude Code maps five-hour and weekly status-line rate limits")
func claudeCodeMapsRateLimits() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": 1749999940,
          "rate_limits": {
            "five_hour": {
              "used_percentage": 25,
              "resets_at": 1750003600
            },
            "seven_day": {
              "used_percentage": 60,
              "resets_at": 1750600000
            }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .healthy)
    #expect(status.observation.quality == .fresh)
    #expect(status.quotaWindows.count == 2)
    #expect(status.quotaWindows[0].remainingFraction == 0.75)
    #expect(status.quotaWindows[0].resetsAt == Date(timeIntervalSince1970: 1_750_003_600))
    #expect(status.quotaWindows[1].remainingFraction == 0.40)
}

@Test("Claude Code preserves partial rate-limit data without fabricating windows")
func claudeCodePartialRateLimits() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": "2025-06-15T15:05:40.123456Z",
          "rate_limits": {
            "five_hour": {
              "used_percentage": 82
            }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .healthy)
    #expect(status.observation.quality == .partial)
    #expect(status.quotaWindows.map(\.id) == ["claude-code-five-hour"])
    #expect(abs((status.quotaWindows[0].remainingFraction ?? 0) - 0.18) < 0.000_001)
}

@Test("Claude Code stale cache cannot produce ready readiness")
func claudeCodeStaleCache() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": 1749990000,
          "rate_limits": {
            "five_hour": { "used_percentage": 10 },
            "seven_day": { "used_percentage": 20 }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(
            statusFileURL: fileURL,
            maximumAge: 300
        ),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.observation.quality == .stale)
    #expect(
        ReadinessEngine().evaluate(
            providers: [status],
            proxies: [],
            at: claudeConnectorDate
        ).state == .unknown
    )
}

@Test("Claude Code exhausted window becomes a known provider failure")
func claudeCodeExhaustedWindow() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": 1749999940,
          "rate_limits": {
            "five_hour": { "used_percentage": 100 },
            "seven_day": { "used_percentage": 30 }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .exhausted)
    #expect(
        ReadinessEngine().evaluate(
            providers: [status],
            proxies: [],
            at: claudeConnectorDate
        ).state == .blocked
    )
}

@Test("Claude Code stale exhaustion is not treated as a current failure")
func claudeCodeStaleExhaustion() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": 1749990000,
          "rate_limits": {
            "five_hour": { "used_percentage": 100 },
            "seven_day": { "used_percentage": 30 }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(
            statusFileURL: fileURL,
            maximumAge: 300
        ),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .healthy)
    #expect(status.observation.quality == .stale)
    #expect(
        ReadinessEngine().evaluate(
            providers: [status],
            proxies: [],
            at: claudeConnectorDate
        ).state == .unknown
    )
}

@Test("Claude Code future cache is stale instead of trusted")
func claudeCodeFutureCache() async throws {
    let fileURL = try temporaryStatusFile(
        """
        {
          "captured_at": 1750003600,
          "rate_limits": {
            "five_hour": { "used_percentage": 20 },
            "seven_day": { "used_percentage": 30 }
          }
        }
        """
    )
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.observation.quality == .stale)
}

@Test("Claude Code missing cache is unsupported without reading credentials")
func claudeCodeMissingCache() async {
    let fileURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathComponent("claude-code-status.json")
    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .unsupported)
    #expect(status.observation.quality == .unavailable)
    #expect(status.quotaWindows.isEmpty)
}

@Test("Claude Code malformed cache is unavailable and does not leak its body")
func claudeCodeMalformedCache() async throws {
    let secret = "sk-ant-secret-value"
    let fileURL = try temporaryStatusFile("{ \"token\": \"\(secret)\" }")
    defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

    let connector = ClaudeCodeConnector(
        configuration: ClaudeCodeConfiguration(statusFileURL: fileURL),
        now: { claudeConnectorDate }
    )

    guard case .provider(let status) = await connector.refresh() else {
        Issue.record("Expected provider result")
        return
    }

    #expect(status.health == .unknown)
    #expect(status.observation.quality == .unavailable)
    #expect(status.observation.message?.contains(secret) == false)
}

private func temporaryStatusFile(_ contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("claude-code-status.json")
    try Data(contents.utf8).write(to: fileURL, options: .atomic)
    return fileURL
}
