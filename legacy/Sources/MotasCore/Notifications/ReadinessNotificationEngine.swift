import Foundation

public enum ReadinessNotificationSeverity: String, Codable, Sendable, Equatable {
    case low
    case normal
    case critical
}

public struct ReadinessNotificationPolicy: Sendable, Equatable {
    public let cooldown: TimeInterval
    public let notifyUnknown: Bool

    public init(cooldown: TimeInterval = 30 * 60, notifyUnknown: Bool = true) {
        self.cooldown = max(cooldown, 0)
        self.notifyUnknown = notifyUnknown
    }
}

/// Minimal in-memory state needed to suppress duplicate notifications.
public struct ReadinessNotificationHistory: Codable, Sendable, Equatable {
    public let lastEventKey: String?
    public let lastNotifiedAt: Date?

    public init(lastEventKey: String? = nil, lastNotifiedAt: Date? = nil) {
        self.lastEventKey = lastEventKey
        self.lastNotifiedAt = lastNotifiedAt
    }
}

/// A safe, normalized event suitable for a future UserNotifications adapter.
/// It contains no raw connector payload, endpoint, credential or response body.
public struct ReadinessNotificationEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let state: ReadinessState
    public let severity: ReadinessNotificationSeverity
    public let sourceID: String?
    public let reason: String
    public let occurredAt: Date

    public init(
        id: String,
        state: ReadinessState,
        severity: ReadinessNotificationSeverity,
        sourceID: String?,
        reason: String,
        occurredAt: Date
    ) {
        self.id = id
        self.state = state
        self.severity = severity
        self.sourceID = sourceID
        self.reason = reason
        self.occurredAt = occurredAt
    }
}

public struct ReadinessNotificationDecision: Sendable, Equatable {
    public let event: ReadinessNotificationEvent?
    public let history: ReadinessNotificationHistory

    public init(
        event: ReadinessNotificationEvent?,
        history: ReadinessNotificationHistory
    ) {
        self.event = event
        self.history = history
    }
}

/// Converts meaningful readiness changes into deduplicated notification events.
///
/// This type deliberately does not request permission or call UserNotifications;
/// it is deterministic Core logic that can be tested without a signed app.
public struct ReadinessNotificationEngine: Sendable {
    public let policy: ReadinessNotificationPolicy

    public init(policy: ReadinessNotificationPolicy = .init()) {
        self.policy = policy
    }

    public func evaluate(
        previous: StatusSnapshot?,
        current: StatusSnapshot,
        at date: Date,
        history: ReadinessNotificationHistory = .init()
    ) -> ReadinessNotificationDecision {
        guard let previous else {
            return ReadinessNotificationDecision(event: nil, history: history)
        }

        guard let candidate = candidate(
            previous: previous.readiness,
            current: current.readiness,
            at: date
        ) else {
            return ReadinessNotificationDecision(event: nil, history: history)
        }

        if candidate.id == history.lastEventKey,
           let lastNotifiedAt = history.lastNotifiedAt,
           date.timeIntervalSince(lastNotifiedAt) < policy.cooldown
        {
            return ReadinessNotificationDecision(event: nil, history: history)
        }

        let nextHistory = ReadinessNotificationHistory(
            lastEventKey: candidate.id,
            lastNotifiedAt: date
        )
        return ReadinessNotificationDecision(event: candidate, history: nextHistory)
    }
}

private extension ReadinessNotificationEngine {
    func candidate(
        previous: ReadinessAssessment,
        current: ReadinessAssessment,
        at date: Date
    ) -> ReadinessNotificationEvent? {
        let stateChanged = previous.state != current.state
        let sourceChanged = previous.primarySourceID != current.primarySourceID
        let reasonChanged = reason(for: previous) != reason(for: current)

        guard stateChanged || sourceChanged || reasonChanged else { return nil }

        let state = current.state
        guard state != .ready else { return nil }
        if state == .unknown && !policy.notifyUnknown { return nil }

        let reason = reason(for: current)
        let source = current.primarySourceID
        let sourcePart = source ?? "none"
        let id = [state.rawValue, sourcePart, reason].joined(separator: "|")

        return ReadinessNotificationEvent(
            id: id,
            state: state,
            severity: severity(for: state),
            sourceID: source,
            reason: reason,
            occurredAt: date
        )
    }

    func reason(for assessment: ReadinessAssessment) -> String {
        // Titles are controlled by ReadinessEngine and are safer/stabler than
        // copying dynamic explanations (which may contain changing percentages).
        assessment.title
    }

    func severity(for state: ReadinessState) -> ReadinessNotificationSeverity {
        switch state {
        case .blocked, .proxyDown:
            .critical
        case .fallback, .caution:
            .normal
        case .unknown:
            .low
        case .ready:
            .low
        }
    }
}
