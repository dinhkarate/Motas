import SwiftUI
import MotasCore

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("Prototype scenario") {
                Picker("Readiness", selection: stateBinding) {
                    Text("Ready").tag(ReadinessState.ready)
                    Text("Caution").tag(ReadinessState.caution)
                    Text("Fallback").tag(ReadinessState.fallback)
                    Text("Proxy Down").tag(ReadinessState.proxyDown)
                }
                .pickerStyle(.segmented)
                Text("Scenario controls apply to demo mode. Set connector environment variables to monitor local services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Connectors") {
                LabeledContent("Claude Code", value: "Mock")
                LabeledContent("9Router", value: "Mock")
                LabeledContent("CLIProxyAPI", value: "Mock")
                Text("Real connector setup will replace these fixtures in the next prototype tasks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Refresh") {
                LabeledContent("Current mode", value: "Manual")
                Text("Use Refresh in the menu bar popover. Scheduled refresh will be added in the MVP phase.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                LabeledContent("Theme", value: "Follow System")
                Text("Motas currently follows the macOS light or dark appearance automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Privacy") {
                Text("Motas stores connector credentials in Keychain and shares only normalized, non-secret snapshots with its desktop widget.")
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 520, height: 360)
    }

    private var stateBinding: Binding<ReadinessState> {
        Binding(
            get: { model.snapshot.readiness.state },
            set: { model.selectScenario($0) }
        )
    }
}
