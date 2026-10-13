import Foundation
import Testing
@testable import MotasCore

private let notificationDate = Date(timeIntervalSince1970: 1_750_000_000)

private func notificationSnapshot(
    _ state: ReadinessState,
    title: String,
    sourceID: String? = "claude-code-local",
    at date: Date = notificationDate
) -> StatusSnapshot {
    StatusSnapshot(
        capturedAt: date,
        readiness: ReadinessAssessment(
            state: state,
            title: title,
            explanation: "Private connector explanation should not enter an event.",
            primarySourceID: sourceID,
            evaluatedAt: date
        ),
        providers: [],
        proxies: []
    )
}

@Test("Initial snapshot produces no notification")
func notificationInitialSnapshotSuppressed() {
    let current = notificationSnapshot(.ready, title: "AI stack ready")
    let decision = ReadinessNotificationEngine().evaluate(
        previous: nil,
        current: current,
        at: notificationDate
    )

    #expect(decision.event == nil)
    #expect(decision.history == .init())
}

@Test("Meaningful readiness transitions produce mapped events")
func notificationStateTransitions() {
    let cases: [(ReadinessState, ReadinessNotificationSeverity)] = [
        (.caution, .normal),
        (.fallback, .normal),
        (.blocked, .critical),
        (.proxyDown, .critical),
        (.unknown, .low),
    ]

    for (state, severity) in cases {
        let previous = notificationSnapshot(.ready, title: "AI stack ready")
        let current = notificationSnapshot(state, title: state.rawValue.capitalized)
        let decision = ReadinessNotificationEngine().evaluate(
            previous: previous,
            current: current,
            at: notificationDate
        )

        #expect(decision.event?.state == state)
        #expect(decision.event?.severity == severity)
        #expect(decision.event?.sourceID == "claude-code-local")
    }
}

@Test("Returning to ready produces no notification")
func readyTransitionIsSilent() {
    let previous = notificationSnapshot(.blocked, title: "AI stack blocked")
    let current = notificationSnapshot(.ready, title: "AI stack ready")
    let decision = ReadinessNotificationEngine().evaluate(
        previous: previous,
        current: current,
        at: notificationDate
    )

    #expect(decision.event == nil)
}

@Test("Unchanged readiness does not duplicate notifications")
func unchangedReadinessIsSilent() {
    let snapshot = notificationSnapshot(.caution, title: "Quota running low")
    let decision = ReadinessNotificationEngine().evaluate(
        previous: snapshot,
        current: snapshot,
        at: notificationDate
    )

    #expect(decision.event == nil)
}

@Test("Cooldown suppresses repeated matching events")
func notificationCooldown() {
    let previous = notificationSnapshot(.ready, title: "AI stack ready")
    let current = notificationSnapshot(.blocked, title: "AI stack blocked")
    let engine = ReadinessNotificationEngine(
        policy: ReadinessNotificationPolicy(cooldown: 300)
    )
    let first = engine.evaluate(previous: previous, current: current, at: notificationDate)
    let second = engine.evaluate(
        previous: previous,
        current: current,
        at: notificationDate.addingTimeInterval(120),
        history: first.history
    )

    #expect(first.event != nil)
    #expect(second.event == nil)
    #expect(second.history == first.history)
}

@Test("Matching event can repeat after cooldown")
func notificationRepeatsAfterCooldown() {
    let previous = notificationSnapshot(.ready, title: "AI stack ready")
    let current = notificationSnapshot(.blocked, title: "AI stack blocked")
    let engine = ReadinessNotificationEngine(
        policy: ReadinessNotificationPolicy(cooldown: 300)
    )
    let first = engine.evaluate(previous: previous, current: current, at: notificationDate)
    let second = engine.evaluate(
        previous: previous,
        current: current,
        at: notificationDate.addingTimeInterval(301),
        history: first.history
    )

    #expect(second.event?.id == first.event?.id)
    #expect(second.history.lastNotifiedAt == notificationDate.addingTimeInterval(301))
}

@Test("Unknown notifications are policy controlled")
func unknownNotificationPolicy() {
    let previous = notificationSnapshot(.ready, title: "AI stack ready")
    let current = notificationSnapshot(.unknown, title: "Readiness unknown")
    let decision = ReadinessNotificationEngine(
        policy: ReadinessNotificationPolicy(notifyUnknown: false)
    ).evaluate(previous: previous, current: current, at: notificationDate)

    #expect(decision.event == nil)
}

@Test("Source or reason changes can produce a new event")
func sourceOrReasonChangeProducesEvent() {
    let previous = notificationSnapshot(
        .caution,
        title: "Quota running low",
        sourceID: "claude-code-local"
    )
    let current = notificationSnapshot(
        .caution,
        title: "Provider degraded",
        sourceID: "9router-local"
    )
    let decision = ReadinessNotificationEngine().evaluate(
        previous: previous,
        current: current,
        at: notificationDate
    )

    #expect(decision.event?.sourceID == "9router-local")
    #expect(decision.event?.reason == "Provider degraded")
}

@Test("Event payload is secret-free and deterministic")
func notificationPayloadPrivacy() throws {
    let previous = notificationSnapshot(.ready, title: "AI stack ready")
    let current = notificationSnapshot(.blocked, title: "AI stack blocked")
    let decision = ReadinessNotificationEngine().evaluate(
        previous: previous,
        current: current,
        at: notificationDate
    )
    let event = try #require(decision.event)
    let encoded = String(decoding: try JSONEncoder().encode(event), as: UTF8.self).lowercased()

    #expect(event.id == "blocked|claude-code-local|AI stack blocked")
    #expect(!encoded.contains("private connector explanation"))
    #expect(!encoded.contains("token"))
    #expect(!encoded.contains("cookie"))
}
