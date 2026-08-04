import SwiftUI
import AppKit
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
    @Published private(set) var settings: MotasSettings
    @Published private(set) var configurationError: String?
    @Published private(set) var settingsSaveError: String?
    @Published private(set) var isSavingSettings = false
    @Published private(set) var isDemoMode = false
    @Published private(set) var sourceLabels: ConnectorSourceLabels
    @Published private(set) var diagnosticsError: String?
    @Published private(set) var connectionTestResults: [ConnectionTestResult] = []
    @Published private(set) var isTestingConnection = false

    private var scenarioIndex = 0
    private var liveConnectors: [any StatusConnector] = []
    private let settingsStore: any ConnectorSettingsStore
    private let secretStore: any ConnectorSecretStore
    private let environment: [String: String]
    private let historyStore: any StatusHistoryStore
    private var history: StatusHistory
    private var persistedSettingsExist = false
    private var settingsLoadError: String?
    private var historyLoadError: String?
    private var refreshCoalescer = RefreshCoalescer()
    private let automaticRefreshScheduler = AutomaticRefreshScheduler()
    private let scenarios: [(Date) -> StatusSnapshot] = [
        MockData.readySnapshot,
        MockData.cautionSnapshot,
        MockData.fallbackSnapshot,
        MockData.proxyDownSnapshot,
    ]

    init(
        settingsStore: (any ConnectorSettingsStore)? = nil,
        secretStore: any ConnectorSecretStore = KeychainConnectorSecretStore(),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        historyStore: (any StatusHistoryStore)? = nil
    ) {
        self.settingsStore = settingsStore ?? Self.defaultSettingsStore()
        self.secretStore = secretStore
        self.environment = environment
        self.historyStore = historyStore ?? Self.defaultHistoryStore()
        self.history = .init()
        settings = .default()
        snapshot = MockData.unknownSnapshot()
        sourceLabels = ConnectorSourceLabels(
            claudeCodeEnabled: .disabled,
            nineRouterEnabled: .disabled,
            cliProxyAPIEnabled: .disabled
        )

        loadSettings()
        loadHistory()
        rebuildConnectors()
        snapshot = isDemoMode ? MockData.readySnapshot() : MockData.unknownSnapshot()
        persistSnapshot()

        configureAutomaticRefresh()
        if !liveConnectors.isEmpty {
            Task { await refresh() }
        }
    }

    /// Coalesces manual, startup, scheduled and post-save refresh requests into
    /// a single active batch plus at most one current-configuration follow-up.
    func refresh() async {
        guard var revision = refreshCoalescer.begin() else { return }
        isRefreshing = true

        while true {
            let connectors = liveConnectors
            let demoMode = isDemoMode

            let nextSnapshot: StatusSnapshot
            if demoMode {
                scenarioIndex = (scenarioIndex + 1) % scenarios.count
                nextSnapshot = scenarios[scenarioIndex](Date())
            } else if !connectors.isEmpty {
                nextSnapshot = await ConnectorRefresher(connectors: connectors).refresh()
            } else {
                nextSnapshot = MockData.unknownSnapshot()
            }

            // A settings change may happen while the connector batch awaits.
            // Do not publish results produced with obsolete endpoints/secrets.
            if refreshCoalescer.shouldApplyResult(capturedAt: revision) {
                snapshot = nextSnapshot
                persistSnapshot()
                if !demoMode {
                    appendHistory(snapshot: nextSnapshot)
                }
            }

            guard refreshCoalescer.finish(), let nextRevision = refreshCoalescer.begin() else {
                isRefreshing = false
                return
            }
            revision = nextRevision
        }
    }

    func selectScenario(_ state: ReadinessState) {
        guard isDemoMode else { return }
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

    func testSettings(
        _ draft: MotasSettings,
        secretUpdates: [ConnectorSecretKey: String]
    ) async -> [ConnectionTestResult] {
        guard !isTestingConnection else { return connectionTestResults }
        do {
            let validated = try draft.validated()
            let resolved = ConnectorConfigurationResolver().resolve(
                settings: validated,
                persistedDocumentExists: false,
                environment: [:],
                secretStore: TransientSecretStore(values: secretUpdates)
            )
            let connectors = EnvironmentConnectorFactory.connectors(resolved: resolved)
            isTestingConnection = true
            defer { isTestingConnection = false }
            connectionTestResults = await ConnectorTestRunner().run(connectors)
            return connectionTestResults
        } catch {
            connectionTestResults = [
                ConnectionTestResult(
                    id: "settings",
                    name: "Settings",
                    status: .unsupported,
                    quality: .unavailable,
                    message: Self.settingsErrorMessage(error)
                ),
            ]
            return connectionTestResults
        }
    }

    func saveSettings(
        _ draft: MotasSettings,
        secretUpdates: [ConnectorSecretKey: String],
        secretRemovals: Set<ConnectorSecretKey>
    ) async -> Bool {
        guard !isSavingSettings else { return false }

        let validated: MotasSettings
        do {
            validated = try draft.validated()
        } catch {
            settingsSaveError = Self.settingsErrorMessage(error)
            return false
        }

        isSavingSettings = true
        settingsSaveError = nil
        defer { isSavingSettings = false }

        var changedKeychain = false
        do {
            for (key, value) in secretUpdates where !value.isEmpty {
                try secretStore.set(value, for: key)
                changedKeychain = true
            }
            for key in secretRemovals where secretUpdates[key]?.isEmpty != false {
                try secretStore.removeValue(for: key)
                changedKeychain = true
            }
        } catch {
            settingsSaveError = changedKeychain
                ? "Some credentials were updated, but a later Keychain change failed. Retry Save or restore the previous credential."
                : "A credential could not be saved to Keychain. Settings were not changed."
            return false
        }

        do {
            try settingsStore.save(validated)
        } catch {
            settingsSaveError = "Credentials were updated, but settings could not be saved. Retry Save or restore the previous credential."
            return false
        }

        settings = validated
        persistedSettingsExist = true
        settingsLoadError = nil
        refreshCoalescer.configurationDidChange()
        rebuildConnectors()
        configureAutomaticRefresh()
        if liveConnectors.isEmpty {
            snapshot = MockData.unknownSnapshot()
            persistSnapshot()
        }
        await refresh()
        return true
    }

    func diagnosticData(format: DiagnosticExportFormat) -> Data? {
        do {
            let configurations = [
                DiagnosticConnectorConfiguration(
                    id: "claude-code",
                    enabled: settings.claudeCode.isEnabled,
                    statusFileConfigured: !settings.claudeCode.statusFilePath.isEmpty,
                    enabledSource: sourceLabels.claudeCodeEnabled.rawValue
                ),
                DiagnosticConnectorConfiguration(
                    id: "9router",
                    enabled: settings.nineRouter.isEnabled,
                    endpointLabel: EndpointNormalizer.redactedLabel(for: settings.nineRouter.baseURL),
                    enabledSource: sourceLabels.nineRouterEnabled.rawValue
                ),
                DiagnosticConnectorConfiguration(
                    id: "cliproxyapi",
                    enabled: settings.cliProxyAPI.isEnabled,
                    endpointLabel: EndpointNormalizer.redactedLabel(for: settings.cliProxyAPI.baseURL),
                    enabledSource: sourceLabels.cliProxyAPIEnabled.rawValue
                ),
            ]
            let issues = [configurationError, settingsSaveError, lastRefreshError]
                .compactMap { $0 }
            let input = DiagnosticReportInput(
                generatedAt: Date(),
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
                    ?? "development",
                snapshot: snapshot,
                history: history,
                configurations: configurations,
                issues: issues
            )
            let report = DiagnosticReportBuilder().build(input)
            diagnosticsError = nil
            return try DiagnosticReportBuilder().export(report, format: format)
        } catch {
            diagnosticsError = "Diagnostics could not be generated."
            return nil
        }
    }

    @discardableResult
    func resetMotasData() -> Bool {
        var failed = false
        do { try settingsStore.delete() } catch { failed = true }
        do { try historyStore.delete() } catch { failed = true }
        for key in ConnectorSecretKey.allCases {
            do { try secretStore.removeValue(for: key) } catch { failed = true }
        }

        let fallbackDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Motas", isDirectory: true)
        let fallbackSnapshot = fallbackDirectory.appendingPathComponent(
            MotasConfiguration.snapshotFilename
        )
        try? FileManager.default.removeItem(at: fallbackSnapshot)
        if let appGroupStore = try? SnapshotStore(
            appGroupIdentifier: MotasConfiguration.appGroupIdentifier
        ) {
            try? FileManager.default.removeItem(at: appGroupStore.fileURL)
        }

        automaticRefreshScheduler.stop()
        settings = .default()
        history = .init()
        persistedSettingsExist = false
        settingsLoadError = nil
        historyLoadError = nil
        settingsSaveError = nil
        diagnosticsError = failed ? "Some Motas data could not be removed." : nil
        refreshCoalescer = .init()
        rebuildConnectors()
        isDemoMode = liveConnectors.isEmpty
        snapshot = isDemoMode ? MockData.readySnapshot() : MockData.unknownSnapshot()
        configureAutomaticRefresh()
        persistSnapshot()
        return !failed
    }

    private func loadHistory() {
        do {
            history = try historyStore.load()
        } catch {
            history = .init()
            historyLoadError = "Saved status history could not be loaded. Motas will rebuild it during refresh."
        }
    }

    private func appendHistory(snapshot: StatusSnapshot) {
        let next = history.appending(snapshot: snapshot, at: snapshot.capturedAt)
        guard next != history else { return }
        history = next
        do {
            try historyStore.save(history)
            historyLoadError = nil
        } catch {
            lastRefreshError = "Status history could not be saved. Live readiness remains available."
        }
    }

    private func loadSettings() {
        do {
            if let loaded = try settingsStore.load() {
                settings = loaded
                persistedSettingsExist = true
            }
        } catch {
            settingsLoadError = "Saved settings could not be loaded. Motas is using in-memory defaults."
        }
    }

    private func rebuildConnectors() {
        let resolved = ConnectorConfigurationResolver().resolve(
            settings: settings,
            persistedDocumentExists: persistedSettingsExist,
            environment: environment,
            secretStore: secretStore
        )
        sourceLabels = resolved.labels
        liveConnectors = EnvironmentConnectorFactory.connectors(resolved: resolved)
        isDemoMode = liveConnectors.isEmpty && !persistedSettingsExist

        let messages = ([settingsLoadError, historyLoadError].compactMap { $0 } + resolved.issues.map(\.message))
        configurationError = messages.isEmpty ? nil : messages.joined(separator: " ")
    }

    private func configureAutomaticRefresh() {
        automaticRefreshScheduler.stop()
        guard settings.automaticRefreshEnabled, !liveConnectors.isEmpty else { return }

        automaticRefreshScheduler.start(
            interval: .seconds(Int(MotasConfiguration.defaultAutomaticRefreshInterval))
        ) { [weak self] in
            await self?.refresh()
        }
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

    private static func defaultSettingsStore() -> any ConnectorSettingsStore {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Motas", isDirectory: true)
        return JSONConnectorSettingsStore(
            fileURL: directory.appendingPathComponent(MotasConfiguration.settingsFilename)
        )
    }

    private static func defaultHistoryStore() -> any StatusHistoryStore {
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0].appendingPathComponent("Motas", isDirectory: true)
        return JSONStatusHistoryStore(
            fileURL: directory.appendingPathComponent("history.json")
        )
    }

    private static func settingsErrorMessage(_ error: Error) -> String {
        switch error {
        case ConnectorSettingsValidationError.invalidScheme:
            "Endpoints must use HTTP or HTTPS."
        case ConnectorSettingsValidationError.missingHost:
            "Endpoints must include a host."
        case ConnectorSettingsValidationError.embeddedCredentials:
            "Put credentials in Keychain fields, not endpoint URLs."
        case ConnectorSettingsValidationError.unsupportedQueryOrFragment:
            "Endpoint URLs cannot contain query strings or fragments."
        case ConnectorSettingsValidationError.unsupportedPath:
            "That endpoint path is not supported."
        case ConnectorSettingsValidationError.invalidStatusFilePath:
            "The Claude Code status file must be an absolute path."
        default:
            "Settings could not be validated."
        }
    }
}
