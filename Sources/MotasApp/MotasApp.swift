import SwiftUI
import MotasCore

@main
struct MotasApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            StatusPopoverView(model: model)
        } label: {
            Label("Motas", systemImage: model.snapshot.readiness.state.symbolName)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: StatusSnapshot
    @Published private(set) var lastRefreshError: String?
    @Published private(set) var isRefreshing = false

    private var scenarioIndex = 0
    private let liveConnectors: [any StatusConnector]
    private let scenarios: [(Date) -> StatusSnapshot] = [
        MockData.readySnapshot,
        MockData.cautionSnapshot,
        MockData.fallbackSnapshot,
        MockData.proxyDownSnapshot,
    ]

    init() {
        liveConnectors = EnvironmentConnectorFactory.connectors()
        snapshot = liveConnectors.isEmpty ? MockData.readySnapshot() : MockData.unknownSnapshot()
        persistSnapshot()
        if !liveConnectors.isEmpty {
            Task { await refresh() }
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        if liveConnectors.isEmpty {
            scenarioIndex = (scenarioIndex + 1) % scenarios.count
            snapshot = scenarios[scenarioIndex](Date())
        } else {
            snapshot = await ConnectorRefresher(connectors: liveConnectors).refresh()
        }
        persistSnapshot()
    }

    func selectScenario(_ state: ReadinessState) {
        switch state {
        case .ready:
            snapshot = MockData.readySnapshot()
        case .caution:
            snapshot = MockData.cautionSnapshot()
        case .fallback:
            snapshot = MockData.fallbackSnapshot()
        case .proxyDown:
            snapshot = MockData.proxyDownSnapshot()
        case .blocked, .unknown:
            snapshot = MockData.readySnapshot()
        }
        persistSnapshot()
    }

    private func persistSnapshot() {
        if let appGroupStore = try? SnapshotStore(
            appGroupIdentifier: MotasConfiguration.appGroupIdentifier
        ), (try? appGroupStore.save(snapshot)) != nil {
            lastRefreshError = nil
            return
        }

        do {
            let directory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0].appendingPathComponent("Motas", isDirectory: true)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let fallbackStore = SnapshotStore(
                fileURL: directory.appendingPathComponent(MotasConfiguration.snapshotFilename)
            )
            try fallbackStore.save(snapshot)
            lastRefreshError = nil
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }
}
