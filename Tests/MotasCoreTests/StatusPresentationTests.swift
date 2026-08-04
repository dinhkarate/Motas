import Foundation
import Testing
@testable import MotasCore

private let presentationNow = Date(timeIntervalSince1970: 1_750_000_000)

@Test("Relative age is deterministic")
func relativeAge() {
    #expect(StatusPresentation.relativeAge(of: presentationNow, now: presentationNow) == "just now")
    #expect(StatusPresentation.relativeAge(of: presentationNow.addingTimeInterval(-120), now: presentationNow) == "2m ago")
    #expect(StatusPresentation.relativeAge(of: presentationNow.addingTimeInterval(-7200), now: presentationNow) == "2h ago")
}

@Test("Reset label handles minutes hours days and passed reset")
func resetLabels() {
    #expect(StatusPresentation.resetLabel(for: presentationNow.addingTimeInterval(180), now: presentationNow) == "resets in 3m")
    #expect(StatusPresentation.resetLabel(for: presentationNow.addingTimeInterval(7200), now: presentationNow) == "resets in 2h")
    #expect(StatusPresentation.resetLabel(for: presentationNow.addingTimeInterval(172_800), now: presentationNow) == "resets in 2d")
    #expect(StatusPresentation.resetLabel(for: presentationNow, now: presentationNow) == "reset passed")
    #expect(StatusPresentation.resetLabel(for: nil, now: presentationNow) == nil)
}

@Test("Remediation maps operational failures")
func remediationMessages() {
    #expect(StatusPresentation.remediation(health: .unauthorized, quality: .unavailable)?.contains("Settings") == true)
    #expect(StatusPresentation.remediation(health: .unreachable, quality: .unavailable)?.contains("Start") == true)
    #expect(StatusPresentation.remediation(health: .exhausted, quality: .fresh)?.contains("fallback") == true)
    #expect(StatusPresentation.remediation(health: .healthy, quality: .stale)?.contains("stale") == true)
    #expect(StatusPresentation.remediation(health: .healthy, quality: .fresh) == nil)
}
