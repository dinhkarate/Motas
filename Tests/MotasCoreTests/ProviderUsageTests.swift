import Foundation
import Testing
@testable import MotasCore

/// One 9Router usage body (HTTP 200) and the reading it must give.
struct UsageCase: Sendable, CustomTestStringConvertible {
    var fixture: String
    var dir: String
    var provider: Provider
    var expected: String

    init(_ fixture: String, dir: String = "live", _ provider: Provider, _ expected: String) {
        self.fixture = fixture
        self.dir = dir
        self.provider = provider
        self.expected = expected
    }

    var testDescription: String { fixture }
}

@Suite("9Router usage bodies")
struct NineRouterUsageTests {
    static let cases: [UsageCase] = [
        UsageCase("9r_prod_usage_antigravity_models", .antigravity, "windows Claude & GPT · Weekly=100, Gemini · Weekly=98 +7 plan=AI Plus"),
        UsageCase("9r_prod_usage_antigravity_weekly", .antigravity, "windows Claude & GPT · Weekly=100, Gemini · Weekly=100 plan=Starter"),
        UsageCase("9r_prod_usage_apikey_unavailable", Provider(rawValue: "openrouter"), "unavailable(6h): Usage not available for this connection"),
        UsageCase("9r_prod_usage_codex_exhausted", .codex, "windows Primary=0 plan=free credits=1"),
        UsageCase("9r_prod_usage_codex_full", .codex, "windows Primary=100 plan=free credits=0"),
        UsageCase("9r_prod_usage_codex_go", .codex, "windows Primary=0 plan=go credits=2"),
        UsageCase("9r_prod_usage_codex_partial", .codex, "windows Primary=62 plan=free credits=0"),
        UsageCase("9r_prod_usage_qoder_401", Provider(rawValue: "qoder"), "credentialRejected: Qoder connected. Usage fetch returned 401."),
        UsageCase("9r_prod_usage_qoder_credits", Provider(rawValue: "qoder"), "unavailable(6h, exceeded): No figures (Qoder reports quota exceeded)"),
        UsageCase("9r_prod_usage_xai_not_implemented", Provider(rawValue: "xai"), "unavailable(6h): Usage API not implemented for xai"),
        UsageCase("9r_usage_codex", .codex, "windows Primary=0 plan=free credits=0"),
        UsageCase("9r_usage_gemini-cli", .geminiCLI, "rateLimited(nil): Gemini CLI quota error (429)."),
        UsageCase("9r_usage_antigravity_api_500", dir: "synthetic", .antigravity, "transient: Antigravity error: Antigravity API error: 500"),
        UsageCase("9r_usage_antigravity_auth_expired", dir: "synthetic", .antigravity,
                  "transient: Antigravity quota API authentication expired. Chat may still work."),
        UsageCase("9r_usage_antigravity_empty_quotas", dir: "synthetic", .antigravity, "transient: No quota figures in this read"),
        UsageCase("9r_usage_antigravity_forbidden", dir: "synthetic", .antigravity,
                  "transient: Antigravity quota API access forbidden. Chat may still work."),
        UsageCase("9r_usage_claude", dir: "synthetic", .claude, "windows 5-hour=65, Weekly=40, Fable · Weekly=80, Sonnet · Weekly=0 plan=Claude Code"),
        UsageCase("9r_usage_claude_admin", dir: "synthetic", .claude, "unavailable(6h): Claude connected. Usage API requires admin permissions."),
        UsageCase("9r_usage_codex_upstream_401", dir: "synthetic", .codex,
                  "credentialRejected: Codex connected. Usage API temporarily unavailable (401)."),
        UsageCase("9r_usage_codex_upstream_403", dir: "synthetic", .codex, "transient: Codex connected. Usage API temporarily unavailable (403)."),
        UsageCase("9r_usage_codex_upstream_502", dir: "synthetic", .codex, "transient: Codex connected. Usage API temporarily unavailable (502)."),
        UsageCase("9r_usage_gemini_cli_quota_403", dir: "synthetic", .geminiCLI, "transient: Gemini CLI quota error (403)."),
        UsageCase("9r_usage_gemini_cli_quota_429", dir: "synthetic", .geminiCLI, "rateLimited(nil): Gemini CLI quota error (429)."),
        UsageCase("9r_usage_qoder_unable", dir: "synthetic", Provider(rawValue: "qoder"), "transient: Qoder connected. Unable to fetch usage: fetch failed"),
    ]

    @Test(arguments: cases)
    func fixtureMapsToItsReading(_ c: UsageCase) {
        #expect(summary(ProviderUsage.nineRouter(Fixture.data(c.fixture, dir: c.dir), provider: c.provider)) == c.expected)
    }

    @Test(arguments: [
        // 1: the chat credential still works; only the quota API refused.
        ("Antigravity quota API authentication expired. Chat may still work.", "transient"),
        ("Usage API error (401). Chat may still work.", "transient"),
        // 2: a status code in the text.
        ("Gemini CLI quota error (429).", "rateLimited(nil)"),
        ("Qoder connected. Usage fetch returned 401.", "credentialRejected"),
        ("Antigravity error: Antigravity API error: 503", "transient"),
        ("Codex connected. Usage API temporarily unavailable (403).", "transient"),
        ("Ollama API error (408)", "transient"),
        ("Vercel API error (500): rate limit", "transient"),
        // 3: no figures by design.
        ("Usage API not implemented for xai", "unavailable(6h)"),
        ("Usage not available for this connection", "unavailable(6h)"),
        ("iFlow connected. Usage tracked per request.", "unavailable(6h)"),
        ("Ollama Cloud connected. No usage limits reported.", "unavailable(6h)"),
        ("Vercel AI Gateway connected. No credit allocation found (BYOK or unfunded account).", "unavailable(6h)"),
        ("Claude connected. Usage API requires admin permissions.", "unavailable(6h)"),
        ("Claude connected. Usage details require admin access.", "unavailable(6h)"),
        ("USAGE NOT AVAILABLE FOR THIS CONNECTION", "unavailable(6h)"),
        // 4: the account's credential.
        ("Groq API key invalid or expired.", "credentialRejected"),
        ("Refresh token invalid or reused. Please re-authorize the connection.", "credentialRejected"),
        ("Gemini CLI project ID not available. Reconnect Gemini CLI, then try again.", "credentialRejected"),
        ("Gemini CLI access token not available.", "credentialRejected"),
        ("Qoder usage unavailable: no access token", "credentialRejected"),
        ("Perplexity API key not available.", "credentialRejected"),
        // 5: rate limits without a status.
        ("Rate limit exceeded, try later", "rateLimited(nil)"),
        ("Too many requests", "rateLimited(nil)"),
        // 6: anything else.
        ("Unable to fetch iFlow usage.", "transient"),
        ("Claude connected. Unable to fetch usage: socket hang up", "transient"),
        ("Kimi response was not JSON.", "transient"),
    ])
    func messageTableRowByRow(_ message: String, _ kind: String) {
        #expect(summary(ProviderUsage.classify(message, extras: UsageExtras())) == "\(kind): \(message)")
    }

    @Test func messageWinsOverQuotas() {
        let body = #"{"message":"Gemini CLI quota error (429).","quotas":{"gemini-2.5-pro":{"remainingPercentage":50}}}"#
        #expect(summary(ProviderUsage.nineRouter(Data(body.utf8), provider: .geminiCLI)) == "rateLimited(nil): Gemini CLI quota error (429).")
    }

    @Test func emptyOrMissingQuotasAreTransientNotUnavailable() {
        for body in [#"{"plan":"free","quotas":{}}"#, #"{"plan":"free"}"#, #"{"quotas":{"session":{"used":3}}}"#] {
            #expect(summary(ProviderUsage.nineRouter(Data(body.utf8), provider: .codex)) == "transient: No quota figures in this read")
        }
        #expect(summary(ProviderUsage.nineRouter(Data("<html>".utf8), provider: .codex)) == "transient: Unreadable usage response")
    }

    @Test func qoderAllZeroTotalsAreUnmeteredWithExtras() throws {
        let reading = ProviderUsage.nineRouter(Fixture.data("9r_prod_usage_qoder_credits"), provider: Provider(rawValue: "qoder"))
        guard case .unavailable(_, let recheck, let extras) = reading else { Issue.record("expected unavailable"); return }
        #expect(recheck == 6 * 3600)
        #expect(extras == UsageExtras(quotaExceeded: true))

        let plain = ProviderUsage.nineRouter(Data(#"{"quotas":{"user":{"total":0,"used":0}}}"#.utf8), provider: Provider(rawValue: "qoder"))
        #expect(summary(plain) == "unavailable(6h): No figures reported")
    }

    @Test func remainingFractionRules() throws {
        let body = #"{"quotas":{"a":{"total":200,"used":50},"b":{"total":4,"remaining":1},"c":{"total":0,"used":0},"d":{"remainingPercentage":150},"e":{"unlimited":true}}}"#
        guard case .windows(let windows, _, _) = ProviderUsage.nineRouter(Data(body.utf8), provider: Provider(rawValue: "kimi")) else {
            Issue.record("expected windows"); return
        }
        #expect(windows.map(\.id) == ["a", "b", "d", "e"])
        #expect(windows.map(\.remainingFraction) == [0.75, 0.25, 1, 1])
        #expect(windows.map(\.label) == ["A", "B", "D", "E (unlimited)"])
        #expect(windows.allSatisfy { $0.role == .limit && $0.group == nil && $0.period == $0.id })
    }

    @Test func codexKeysAreLanesAndTheWindowIsPrimaryNotALength() throws {
        guard case .windows(let windows, _, _) = ProviderUsage.nineRouter(Fixture.data("9r_prod_usage_codex_partial"), provider: .codex) else {
            Issue.record("expected windows"); return
        }
        let session = try #require(windows.first)
        #expect(session.label == "Primary")
        #expect(session.duration == nil)
        #expect(session.period == "primary" && session.group == nil && session.role == .limit)
        #expect(session.resetsAt == Dates.iso("2026-11-28T06:16:34.000Z"))

        let body = #"{"plan":"plus","quotas":{"session":{"remainingPercentage":60},"weekly":{"remainingPercentage":90},"review_session":{"remainingPercentage":100},"spark_weekly":{"remainingPercentage":10}}}"#
        guard case .windows(let all, _, _) = ProviderUsage.nineRouter(Data(body.utf8), provider: .codex) else { Issue.record("expected windows"); return }
        let byKey = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        #expect(byKey["weekly"]?.label == "Secondary")
        #expect(byKey["review_session"]?.label == "Code review · Primary")
        #expect(byKey["review_session"]?.group == "review")
        #expect(byKey["spark_weekly"]?.label == "Spark · Secondary")
        #expect(byKey["spark_weekly"]?.period == "secondary")
    }

    @Test func antigravityRolesWithFamilyBuckets() throws {
        guard case .windows(let windows, let plan, _) = ProviderUsage.nineRouter(Fixture.data("9r_prod_usage_antigravity_models"),
                                                                               provider: .antigravity) else {
            Issue.record("expected windows"); return
        }
        #expect(plan == "AI Plus")
        let byKey = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        #expect(byKey["gemini_weekly"]?.role == .limit)
        #expect(byKey["gemini_weekly"]?.group == "gemini")
        #expect(byKey["gemini_weekly"]?.period == "weekly")
        #expect(byKey["gemini_weekly"]?.label == "Gemini · Weekly")
        #expect(byKey["claude_gpt_weekly"]?.label == "Claude & GPT · Weekly")
        // A family with a bucket: its text models are details only.
        for key in ["gemini-3.8-flash-high", "gemini-3.8-flash-low", "gemini-3.8-flash-medium"] {
            #expect(byKey[key]?.group == "gemini" && byKey[key]?.role == .detail && byKey[key]?.period == nil)
        }
        for key in ["claude-opus-4-6-thinking", "claude-sonnet-4-6", "gpt-oss-120b-medium"] {
            #expect(byKey[key]?.group == "claude-gpt" && byKey[key]?.role == .detail)
        }
        #expect(byKey["gemini-3.1-flash-image"]?.group == "image")
        #expect(byKey["gemini-3.1-flash-image"]?.role == .detail)
        #expect(byKey["gemini-3.8-flash-high"]?.label == "Gemini 3.8 Flash (High)")
    }

    @Test func antigravityModelsCountWhenTheFamilyHasNoBucket() throws {
        let body = #"{"plan":"Antigravity","quotas":{"gemini-3.8-flash-high":{"remainingPercentage":40,"displayName":"Gemini 3.8 Flash (High)"},"claude-sonnet-4-6":{"remainingPercentage":70},"gemini-3.1-flash-image":{"remainingPercentage":0},"tab_flash_lite":{"remainingPercentage":5},"claude_gpt_session":{"remainingPercentage":80}}}"#
        guard case .windows(let windows, let plan, _) = ProviderUsage.nineRouter(Data(body.utf8), provider: .antigravity) else {
            Issue.record("expected windows"); return
        }
        #expect(plan == nil)
        let byKey = Dictionary(uniqueKeysWithValues: windows.map { ($0.id, $0) })
        #expect(byKey["gemini-3.8-flash-high"]?.role == .model)
        #expect(byKey["claude-sonnet-4-6"]?.role == .detail)    // claude_gpt_session is the family's limit
        #expect(byKey["claude_gpt_session"]?.label == "Claude & GPT · 5-hour")
        #expect(byKey["claude_gpt_session"]?.period == "5h")
        #expect(byKey["gemini-3.1-flash-image"]?.role == .detail)
        #expect(byKey["tab_flash_lite"]?.group == "other")
        #expect(byKey["tab_flash_lite"]?.role == .detail)
    }

    @Test func claudeKeysAndGroups() throws {
        guard case .windows(let windows, _, _) = ProviderUsage.nineRouter(Fixture.data("9r_usage_claude", dir: "synthetic"), provider: .claude) else {
            Issue.record("expected windows"); return
        }
        #expect(windows.map(\.id) == ["session (5h)", "weekly (7d)", "weekly fable (7d)", "weekly sonnet (7d)"])
        #expect(windows.map(\.group) == [nil, nil, "fable", "sonnet"])
        #expect(windows.map(\.period) == ["5h", "weekly", "weekly", "weekly"])
        #expect(windows.allSatisfy { $0.role == .limit })

        let spaced = #"{"quotas":{"weekly Opus 4 (7d)":{"remainingPercentage":30}}}"#
        guard case .windows(let opus, _, _) = ProviderUsage.nineRouter(Data(spaced.utf8), provider: .claude) else { Issue.record("expected windows"); return }
        #expect(opus.first?.group == "opus-4")
    }

    @Test func geminiCLIModelsAreGroupedByFamily() throws {
        let body = #"{"plan":"Free","quotas":{"gemini-2.5-pro":{"remainingPercentage":40},"gemini-2.5-flash":{"remainingPercentage":70},"gemini-2.5-flash-lite":{"remainingPercentage":90}}}"#
        guard case .windows(let windows, let plan, _) = ProviderUsage.nineRouter(Data(body.utf8), provider: .geminiCLI) else {
            Issue.record("expected windows"); return
        }
        #expect(plan == "Free")
        #expect(windows.map(\.group) == ["flash", "flash-lite", "pro"])
        #expect(windows.allSatisfy { $0.role == .limit && $0.period == nil })
        #expect(windows.map(\.label) == ["gemini-2.5-flash", "gemini-2.5-flash-lite", "gemini-2.5-pro"])
    }

    @Test func planNormalisation() {
        #expect(ProviderUsage.normalisedPlan(nil) == nil)
        #expect(ProviderUsage.normalisedPlan("") == nil)
        #expect(ProviderUsage.normalisedPlan("  ") == nil)
        #expect(ProviderUsage.normalisedPlan("unknown") == nil)
        #expect(ProviderUsage.normalisedPlan("Unknown") == nil)
        #expect(ProviderUsage.normalisedPlan(" plus ") == "plus")

        let unknown = #"{"plan":"unknown","quotas":{"session":{"remainingPercentage":50}}}"#
        #expect(summary(ProviderUsage.nineRouter(Data(unknown.utf8), provider: .codex)) == "windows Primary=50 plan=nil")

        func antigravity(_ root: String) -> String? { ProviderUsage.antigravityPlan(JSON.object(Data(root.utf8))!) }
        #expect(antigravity(#"{"plan":"Antigravity","subscriptionInfo":{"paidTier":{"name":"Google AI Plus"}}}"#) == "AI Plus")
        #expect(antigravity(#"{"plan":"Antigravity","subscriptionInfo":{"paidTier":{"name":"Antigravity Starter Quota"}}}"#) == "Starter")
        #expect(antigravity(#"{"plan":"Antigravity"}"#) == nil)
        #expect(antigravity(#"{"plan":"Google AI Ultra"}"#) == "AI Ultra")
    }
}

@Suite("CLIProxyAPI upstream bodies")
struct CPAUsageTests {
    func body(_ fixture: String) throws -> Data {
        let envelope = try #require(JSON.object(Fixture.data(fixture)))
        return Data(try #require(envelope["body"] as? String).utf8)
    }

    @Test func codexFreePlanHasOneThirtyDayWindow() throws {
        guard case .windows(let windows, let plan, let extras) = ProviderUsage.codex(try body("cpa_apicall_codex_usage"), now: productionNow) else {
            Issue.record("expected windows"); return
        }
        #expect(plan == "free")
        #expect(extras.resetCredits == 0)
        #expect(windows.count == 1)
        #expect(windows[0].label == "30-day")
        #expect(windows[0].id == "primary_window")
        #expect(windows[0].period == "primary")
        #expect(windows[0].duration == 2_592_000)
        #expect(windows[0].remainingFraction == 0)
        #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_792_909_832))
    }

    @Test func codexLabelsFromTheReportedDuration() throws {
        let body = #"""
        {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":600},
         "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_at":2}},
         "code_review_rate_limit":{"primary_window":{"used_percent":0,"limit_window_seconds":604800}},
         "additional_rate_limits":[{"limit_name":"GPT-5.3-Codex-Spark","rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":18000}}}],
         "rate_limit_reset_credits":{"available_count":5,"applicable_available_count":2}}
        """#
        guard case .windows(let windows, _, let extras) = ProviderUsage.codex(Data(body.utf8), now: productionNow) else {
            Issue.record("expected windows"); return
        }
        #expect(windows.map(\.label) == ["5-hour", "Weekly", "Code review · Weekly", "Spark · 5-hour"])
        #expect(windows.map(\.group) == [nil, nil, "review", "spark"])
        #expect(abs(windows[0].remainingFraction - 0.6) < 1e-9)
        #expect(windows[0].resetsAt == productionNow.addingTimeInterval(600))
        #expect(extras.resetCredits == 2)

        let available = #"{"rate_limit":{"primary_window":{"used_percent":1}},"rate_limit_reset_credits":{"available_count":4}}"#
        guard case .windows(_, _, let other) = ProviderUsage.codex(Data(available.utf8), now: productionNow) else { Issue.record("expected windows"); return }
        #expect(other.resetCredits == 4)
    }

    @Test func noFiguresIsATransientFailureNeverUnavailable() {
        #expect(summary(ProviderUsage.codex(Data(#"{"plan_type":"free","rate_limit":null}"#.utf8), now: productionNow))
                == "transient: No quota figures in this read")
        #expect(summary(ProviderUsage.antigravity(Data(#"{"groups":[]}"#.utf8))) == "transient: No quota figures in this read")
        #expect(summary(ProviderUsage.claude(Data(#"{"extra_usage":{}}"#.utf8))) == "transient: No quota figures in this read")
        let junk = Data("<html>".utf8)
        for reading in [ProviderUsage.codex(junk, now: productionNow), ProviderUsage.antigravity(junk), ProviderUsage.claude(junk)] {
            #expect(summary(reading) == "transient: Unreadable usage response")
        }
    }

    @Test func antigravityQuotaSummaryGroups() throws {
        guard case .windows(let windows, _, _) = ProviderUsage.antigravity(try body("cpa_apicall_antigravity_0")) else {
            Issue.record("expected windows"); return
        }
        #expect(windows.map(\.id) == ["gemini-weekly", "3p-weekly"])
        #expect(windows.map(\.label) == ["Gemini · Weekly", "Claude & GPT · Weekly"])
        #expect(windows.map(\.group) == ["gemini", "claude-gpt"])
        #expect(windows.allSatisfy { $0.role == .limit && $0.period == "weekly" && $0.remainingFraction == 1 && $0.resetsAt != nil })
    }

    @Test func antigravityModelsSkipInternalOnes() throws {
        guard case .windows(let windows, _, _) = ProviderUsage.antigravity(try body("cpa_apicall_antigravity_2")) else {
            Issue.record("expected windows"); return
        }
        #expect(windows.map(\.id) == ["gemini-2.5-pro", "gemini-3.1-flash-image", "gpt-oss-120b-medium"])
        #expect(windows.map(\.role) == [.model, .detail, .model])
        #expect(windows.map(\.group) == ["gemini", "image", "claude-gpt"])
        #expect(windows[0].label == "Gemini 2.5 Pro")
    }

    @Test func claudeUsageKeys() throws {
        let body = #"{"five_hour":{"utilization":20,"resets_at":"2026-11-02T20:00:00Z"},"seven_day":{"utilization":50},"seven_day_opus":{"utilization":100},"extra_usage":{"is_enabled":false}}"#
        guard case .windows(let windows, _, _) = ProviderUsage.claude(Data(body.utf8)) else { Issue.record("expected windows"); return }
        #expect(windows.map(\.label) == ["5-hour", "Weekly", "Opus · Weekly"])
        #expect(windows.map(\.period) == ["5h", "weekly", "weekly"])
        #expect(windows.map(\.group) == [nil, nil, "opus"])
        #expect(windows.map(\.remainingFraction) == [0.8, 0.5, 0])
        #expect(windows[0].resetsAt == Dates.iso("2026-11-02T20:00:00Z"))
    }
}

@Suite("QuotaGroups")
struct QuotaGroupsTests {
    @Test func groupLabels() {
        #expect(QuotaGroups.label(provider: .codex, group: "review") == "Code review")
        #expect(QuotaGroups.label(provider: .codex, group: "spark") == "Spark")
        #expect(QuotaGroups.label(provider: .antigravity, group: "gemini") == "Gemini")
        #expect(QuotaGroups.label(provider: .antigravity, group: "claude-gpt") == "Claude & GPT")
        #expect(QuotaGroups.label(provider: .antigravity, group: "image") == "Image")
        #expect(QuotaGroups.label(provider: .antigravity, group: "other") == "Other")
        #expect(QuotaGroups.label(provider: .geminiCLI, group: "flash-lite") == "Flash-Lite")
        #expect(QuotaGroups.label(provider: .claude, group: "sonnet") == "Sonnet")
    }

    @Test func periodLabelsNeverGuessALength() {
        #expect(QuotaGroups.periodLabel("primary", duration: nil) == "Primary")
        #expect(QuotaGroups.periodLabel("secondary", duration: nil) == "Secondary")
        #expect(QuotaGroups.periodLabel("primary", duration: 2_592_000) == "30-day")
        #expect(QuotaGroups.periodLabel("primary", duration: 18_000) == "5-hour")
        #expect(QuotaGroups.periodLabel("secondary", duration: 604_800) == "Weekly")
        #expect(QuotaGroups.periodLabel("primary", duration: 86_400) == "Daily")
        #expect(QuotaGroups.periodLabel("primary", duration: 3 * 86_400) == "3-day")
        #expect(QuotaGroups.periodLabel("primary", duration: 2 * 3600) == "2-hour")
        #expect(QuotaGroups.periodLabel("5h", duration: nil) == "5-hour")
        #expect(QuotaGroups.periodLabel("monthly", duration: nil) == "Monthly")
    }

    @Test func groupOrder() {
        let sorted = ["other", "zeta", "claude-gpt", "image", "alpha", "gemini"].sorted(by: QuotaGroups.precedes)
        #expect(sorted == ["gemini", "claude-gpt", "image", "other", "alpha", "zeta"])
    }
}
