import Foundation
import Testing
@testable import MotasCore

private let historyDate = Date(timeIntervalSince1970: 1_750_000_000)

private func historySnapshot(
    state: ReadinessState,
    sourceID: String? = "claude-code-local",
    at date: Date = historyDate
) -> StatusSnapshot {
    StatusSnapshot(
        capturedAt: date,
        readiness: ReadinessAssessment(
            state: state,
            title: state.rawValue,
            explanation: "safe explanation",
            primarySourceID: sourceID,
            evaluatedAt: date
        ),
        providers: [],
        proxies: []
    )
}

private func historyStore() throws -> JSONStatusHistoryStore {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return JSONStatusHistoryStore(fileURL: directory.appendingPathComponent("history.json"))
}

@Test("Missing history returns empty history")
func missingHistoryReturnsEmpty() throws {
    let store = JSONStatusHistoryStore(
        fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
    )
    #expect(try store.load() == StatusHistory())
}

@Test("History round-trips in chronological order")
func historyRoundTrip() throws {
    let store = try historyStore()
    let first = historySnapshot(state: .ready, at: historyDate)
    let second = historySnapshot(state: .caution, at: historyDate.addingTimeInterval(60))
    let history = StatusHistory()
        .appending(snapshot: second, at: second.capturedAt)
        .appending(snapshot: first, at: first.capturedAt)

    try store.save(history)
    #expect(try store.load() == history)
    #expect(try store.load().entries.map(\.readiness.state) == [.ready, .caution])
}

@Test("Count retention removes oldest entries")
func countRetention() {
    var history = StatusHistory()
    for index in 0..<3 {
        let date = historyDate.addingTimeInterval(Double(index))
        history = history.appending(
            snapshot: historySnapshot(state: .caution, sourceID: "source-\(index)", at: date),
            at: date,
            policy: StatusHistoryPolicy(maximumEntries: 2, maximumAge: 10_000)
        )
    }

    #expect(history.entries.count == 2)
    #expect(history.entries.first?.readiness.primarySourceID == "source-1")
}

@Test("Age retention removes expired entries")
func ageRetention() {
    let old = historySnapshot(state: .ready, at: historyDate)
    let current = historySnapshot(state: .caution, at: historyDate.addingTimeInterval(100))
    var history = StatusHistory().appending(snapshot: old, at: old.capturedAt)
    history = history.appending(
        snapshot: current,
        at: current.capturedAt,
        policy: StatusHistoryPolicy(maximumEntries: 50, maximumAge: 50)
    )

    #expect(history.entries.map(\.readiness.state) == [.caution])
}

@Test("Identical state/source entries are suppressed")
func duplicateEntrySuppressed() {
    let snapshot = historySnapshot(state: .ready)
    var history = StatusHistory().appending(snapshot: snapshot, at: historyDate)
    history = history.appending(
        snapshot: snapshot,
        at: historyDate.addingTimeInterval(60),
        policy: StatusHistoryPolicy(maximumAge: 10_000)
    )

    #expect(history.entries.count == 1)
}

@Test("State or source changes are recorded")
func meaningfulChangeRecorded() {
    let first = historySnapshot(state: .ready, sourceID: "one")
    let second = historySnapshot(state: .caution, sourceID: "two", at: historyDate.addingTimeInterval(1))
    var history = StatusHistory().appending(snapshot: first, at: first.capturedAt)
    history = history.appending(snapshot: second, at: second.capturedAt)

    #expect(history.entries.count == 2)
}

@Test("Malformed history is not silently overwritten")
func malformedHistoryThrows() throws {
    let store = try historyStore()
    try Data("not-json".utf8).write(to: store.fileURL)
    #expect(throws: StatusHistoryStoreError.self) {
        _ = try store.load()
    }
}

@Test("Future history schema throws")
func futureHistorySchemaThrows() throws {
    let store = try historyStore()
    try Data(#"{"schemaVersion":99,"entries":[]}"#.utf8).write(to: store.fileURL)
    #expect(throws: StatusHistoryStoreError.unsupportedSchemaVersion(99)) {
        _ = try store.load()
    }
}

@Test("History encoding contains no secrets or raw explanations")
func historyPrivacy() throws {
    let snapshot = StatusSnapshot(
        capturedAt: historyDate,
        readiness: ReadinessAssessment(
            state: .blocked,
            title: "blocked",
            explanation: "token should not be copied",
            primarySourceID: "source",
            evaluatedAt: historyDate
        ),
        providers: [
            ProviderStatus(
                id: "provider",
                name: "Provider",
                role: .primary,
                health: .degraded,
                observation: Observation(
                    checkedAt: historyDate,
                    quality: .partial,
                    message: "cookie=secret"
                ),
                quotaWindows: [
                    QuotaWindow(
                        id: "window",
                        name: "Window",
                        unit: .percentage,
                        remainingFraction: 0.2
                    ),
                ]
            ),
        ],
        proxies: []
    )
    let history = StatusHistory().appending(snapshot: snapshot, at: historyDate)
    let encoder = JSONEncoder()
    let encoded = String(decoding: try encoder.encode(history), as: UTF8.self).lowercased()

    #expect(!encoded.contains("token should not be copied"))
    #expect(!encoded.contains("cookie=secret"))
    #expect(!encoded.contains("authorization"))
    #expect(!encoded.contains("dashboardtoken"))
}
