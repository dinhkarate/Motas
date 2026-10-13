import Foundation
import Testing
@testable import MotasCore

@Suite("Provider usage parsers (live fixtures)")
struct ProviderUsageTests {
    @Test func codexFreePlanHasSingleThirtyDayWindow() throws {
        let envelope = try #require(JSON.object(Fixture.data("cpa_apicall_codex_usage")))
        let parsed = ProviderUsage.codex(Data((envelope["body"] as! String).utf8))
        #expect(parsed.plan == "free")
        let windows = parsed.quota.windows
        #expect(windows.count == 1)
        #expect(windows[0].label == "30-day")
        #expect(windows[0].duration == 2_592_000)
        #expect(windows[0].remainingFraction == 0)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_909_832))
    }

    @Test func codexLabelsWindowsFromDuration() {
        let body = #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_at":1},"secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":2}}}"#
        let windows = ProviderUsage.codex(Data(body.utf8)).quota.windows
        #expect(windows.map(\.label) == ["5-hour", "Weekly"])
        #expect(abs(windows[0].remainingFraction - 0.6) < 1e-9)
    }

    @Test func codexWithoutWindowsIsUnavailableNotZero() {
        let parsed = ProviderUsage.codex(Data(#"{"plan_type":"free","rate_limit":null}"#.utf8))
        #expect(parsed.quota == .unavailable("No rate-limit window reported"))
    }

    @Test func antigravityQuotaSummaryGroups() throws {
        let envelope = try #require(JSON.object(Fixture.data("cpa_apicall_antigravity_0")))
        let windows = ProviderUsage.antigravity(Data((envelope["body"] as! String).utf8)).quota.windows
        #expect(windows.map(\.id) == ["gemini-weekly", "3p-weekly"])
        #expect(windows[0].label == "Gemini Models · Weekly")
        #expect(windows[1].label == "Claude and GPT models · Weekly")
        #expect(windows.allSatisfy { $0.remainingFraction == 1 && $0.duration == 604_800 && $0.resetsAt != nil })
    }

    @Test func antigravityFetchAvailableModelsFallback() throws {
        let envelope = try #require(JSON.object(Fixture.data("cpa_apicall_antigravity_2")))
        let windows = ProviderUsage.antigravity(Data((envelope["body"] as! String).utf8)).quota.windows
        #expect(windows.count == 4)
        // Real payloads omit resetTime for some models; it must stay nil, not be invented.
        #expect(windows.first { $0.id == "chat_20706" }?.resetsAt == nil)
        #expect(windows.first { $0.id == "gemini-2.5-pro" }?.resetsAt != nil)
    }

    @Test func nineRouterCodexSessionExhausted() {
        let parsed = ProviderUsage.nineRouter(Fixture.data("9r_usage_codex"))
        #expect(parsed.plan == "free")
        let windows = parsed.quota.windows
        #expect(windows.map(\.label) == ["Session"])
        #expect(windows[0].remainingFraction == 0)
        #expect(windows[0].resetsAt != nil)
    }

    @Test func nineRouterMessageOnlyIsUnavailable() {
        let parsed = ProviderUsage.nineRouter(Fixture.data("9r_usage_gemini-cli"))
        #expect(parsed.plan == "Free")
        #expect(parsed.quota == .unavailable("Gemini CLI quota error (429)."))
    }

    @Test func nineRouterUnlimitedAndPercentage() {
        let body = #"{"quotas":{"weekly":{"remainingPercentage":25,"resetAt":"2026-10-20T00:00:00Z"},"daily":{"unlimited":true}}}"#
        let windows = ProviderUsage.nineRouter(Data(body.utf8)).quota.windows
        #expect(windows.map(\.label) == ["Daily (unlimited)", "Weekly"])
        #expect(windows[1].remainingFraction == 0.25)
    }

    @Test func malformedPayloadsFailInsteadOfGuessing() {
        let junk = Data("<html>".utf8)
        for parse in [ProviderUsage.codex, ProviderUsage.antigravity, ProviderUsage.claude, ProviderUsage.nineRouter] {
            guard case .failed = parse(junk).quota else { Issue.record("expected .failed"); continue }
        }
    }
}
