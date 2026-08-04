import SwiftUI
import AppKit
import MotasCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    @State private var draft: MotasSettings
    @State private var nineRouterURL: String
    @State private var cliProxyAPIURL: String
    @State private var dashboardToken = ""
    @State private var cliToken = ""
    @State private var proxyAPIKey = ""
    @State private var managementKey = ""
    @State private var secretRemovals: Set<ConnectorSecretKey> = []
    @State private var showResetConfirmation = false
    @State private var diagnosticsMessage: String?

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _nineRouterURL = State(initialValue: model.settings.nineRouter.baseURL.absoluteString)
        _cliProxyAPIURL = State(initialValue: model.settings.cliProxyAPI.baseURL.absoluteString)
    }

    var body: some View {
        Form {
            generalSection
            claudeCodeSection
            nineRouterSection
            cliProxyAPISection

            if model.isDemoMode {
                prototypeSection
            }

            if let configurationError = model.configurationError {
                Section("Configuration") {
                    Text(configurationError)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let settingsSaveError = model.settingsSaveError {
                Section("Save failed") {
                    Text(settingsSaveError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            diagnosticsSection

            HStack {
                Spacer()
                Button("Save Settings") {
                    Task { await save() }
                }
                .disabled(model.isSavingSettings)
                .keyboardShortcut("s")
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 580, height: 680)
        .onChange(of: model.settings) { _, settings in
            syncDraft(from: settings)
        }
        .alert("Reset Motas data?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                if model.resetMotasData() {
                    diagnosticsMessage = "Motas data was reset. Claude Code cache was left untouched."
                } else {
                    diagnosticsMessage = "Some Motas data could not be reset."
                }
            }
        } message: {
            Text("This removes Motas settings, history, snapshots and stored proxy credentials. It does not remove Claude Code files.")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            HStack {
                Button("Copy report") {
                    guard let data = model.diagnosticData(format: .markdown),
                          let text = String(data: data, encoding: .utf8)
                    else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    diagnosticsMessage = "Sanitized diagnostics copied."
                }
                Button("Save JSON…") {
                    saveDiagnosticsJSON()
                }
                Button("Reset Motas data…", role: .destructive) {
                    showResetConfirmation = true
                }
            }
            if let diagnosticsMessage {
                Text(diagnosticsMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let diagnosticsError = model.diagnosticsError {
                Text(diagnosticsError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Text("Reports include normalized status and bounded history only; credentials and raw connector responses are excluded.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func saveDiagnosticsJSON() {
        guard let data = model.diagnosticData(format: .json) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "motas-diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: [.atomic])
            diagnosticsMessage = "Sanitized diagnostics saved."
        } catch {
            diagnosticsMessage = "Diagnostics could not be saved."
        }
    }

    private var generalSection: some View {
        Section("Refresh") {
            Toggle("Automatic refresh", isOn: $draft.automaticRefreshEnabled)
            Text("Refreshes every 5 minutes while Motas is running.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var claudeCodeSection: some View {
        Section("Claude Code") {
            Toggle("Monitor Claude Code", isOn: $draft.claudeCode.isEnabled)
            TextField("Status file", text: $draft.claudeCode.statusFilePath)
                .textFieldStyle(.roundedBorder)
            sourceLabel(for: model.sourceLabels.claudeCodeEnabled)
            Text("Motas reads the sanitized status-line cache; it does not store a Claude credential.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var nineRouterSection: some View {
        GroupBox("9Router") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Monitor 9Router", isOn: $draft.nineRouter.isEnabled)
                TextField("Endpoint", text: $nineRouterURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Dashboard token (leave empty to keep)", text: $dashboardToken)
                secretStatus("Dashboard token", source: model.sourceLabels.nineRouterDashboard)
                stagedRemovalButton(for: .nineRouterDashboardToken)

                SecureField("CLI token (leave empty to keep)", text: $cliToken)
                secretStatus("CLI token", source: model.sourceLabels.nineRouterCLI)
                stagedRemovalButton(for: .nineRouterCLIToken)
            }
        }
    }

    private var cliProxyAPISection: some View {
        GroupBox("CLIProxyAPI") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Monitor CLIProxyAPI", isOn: $draft.cliProxyAPI.isEnabled)
                TextField("Endpoint", text: $cliProxyAPIURL)
                    .textFieldStyle(.roundedBorder)

                SecureField("Proxy API key (leave empty to keep)", text: $proxyAPIKey)
                secretStatus("Proxy API key", source: model.sourceLabels.cliProxyAPIKey)
                stagedRemovalButton(for: .cliProxyAPIProxyKey)

                SecureField("Management key (leave empty to keep)", text: $managementKey)
                secretStatus("Management key", source: model.sourceLabels.cliProxyAPIManagementKey)
                stagedRemovalButton(for: .cliProxyAPIManagementKey)
            }
        }
    }

    private var prototypeSection: some View {
        Section("Prototype scenario") {
            Picker("Readiness", selection: stateBinding) {
                Text("Ready").tag(ReadinessState.ready)
                Text("Caution").tag(ReadinessState.caution)
                Text("Fallback").tag(ReadinessState.fallback)
                Text("Proxy Down").tag(ReadinessState.proxyDown)
            }
            .pickerStyle(.segmented)
            Text("Demo controls disappear after connector settings are saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourceLabel(for source: ConnectorConfigurationSource) -> some View {
        Text(source == .environment ? "Enabled by environment override." : "Saved Settings controls this connector.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func secretStatus(_ label: String, source: SecretSource) -> some View {
        Text("\(label): \(secretSourceLabel(source))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func stagedRemovalButton(for key: ConnectorSecretKey) -> some View {
        if secretRemovals.contains(key) {
            Button("Keep stored credential") {
                secretRemovals.remove(key)
            }
            .buttonStyle(.link)
            Text("Credential will be removed when you save.")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Button("Remove stored credential") {
                secretRemovals.insert(key)
            }
            .buttonStyle(.link)
        }
    }

    private var stateBinding: Binding<ReadinessState> {
        Binding(
            get: { model.snapshot.readiness.state },
            set: { model.selectScenario($0) }
        )
    }

    private func save() async {
        var settings = draft
        settings.nineRouter.baseURL = URL(string: nineRouterURL)
            ?? URL(string: "invalid://missing-host")!
        settings.cliProxyAPI.baseURL = URL(string: cliProxyAPIURL)
            ?? URL(string: "invalid://missing-host")!

        let updates: [ConnectorSecretKey: String] = [
            .nineRouterDashboardToken: dashboardToken,
            .nineRouterCLIToken: cliToken,
            .cliProxyAPIProxyKey: proxyAPIKey,
            .cliProxyAPIManagementKey: managementKey,
        ]
        if await model.saveSettings(
            settings,
            secretUpdates: updates,
            secretRemovals: secretRemovals
        ) {
            dashboardToken = ""
            cliToken = ""
            proxyAPIKey = ""
            managementKey = ""
            secretRemovals = []
        }
    }

    private func syncDraft(from settings: MotasSettings) {
        draft = settings
        nineRouterURL = settings.nineRouter.baseURL.absoluteString
        cliProxyAPIURL = settings.cliProxyAPI.baseURL.absoluteString
    }

    private func secretSourceLabel(_ source: SecretSource) -> String {
        switch source {
        case .environment: "Provided by environment"
        case .keychain: "Stored in Keychain"
        case .unset: "Not configured"
        }
    }
}
