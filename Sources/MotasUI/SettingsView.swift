import AppKit
import MotasCore
import MotasDesign
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            ProxiesTab(model: model).tabItem { Label("Proxies", systemImage: "server.rack") }
            QuotasTab(model: model).tabItem { Label("Quotas", systemImage: "gauge.with.dots.needle.33percent") }
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
        .padding(.top, 8)
        .environment(\.locale, Design.locale)
    }
}

// MARK: Proxies

struct ProxiesTab: View {
    @ObservedObject var model: AppModel
    @State private var editing: ProxyConfig?
    @State private var isNew = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.settings.proxies.isEmpty {
                ContentUnavailableView("No proxies", systemImage: "server.rack",
                                       description: Text("Add a CLIProxyAPI or 9Router server."))
            } else {
                List {
                    ForEach(model.settings.proxies) { proxy in
                        HStack(spacing: 8) {
                            Toggle("", isOn: Binding(
                                get: { proxy.isEnabled },
                                set: { on in perform { var p = proxy; p.isEnabled = on; try await model.save(p, secret: nil) } }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            Circle().fill(status(proxy).color).frame(width: 7, height: 7)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(proxy.name)
                                Text("\(proxy.kind.displayName) · \(proxy.baseURL.absoluteString)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit…") { isNew = false; editing = proxy }
                        }
                        .help(status(proxy).message)
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Add Proxy…") {
                    isNew = true
                    editing = ProxyConfig(name: "", kind: .cliProxyAPI, baseURL: ProxyKind.cliProxyAPI.defaultBaseURL)
                }
            }
        }
        .padding()
        .sheet(item: $editing) { proxy in
            ProxyEditor(model: model, original: proxy, isNew: isNew) { editing = nil }
        }
    }

    private func status(_ proxy: ProxyConfig) -> (color: Color, message: String) {
        guard let snapshot = model.snapshot.proxies.first(where: { $0.id == proxy.id }) else {
            return (.secondary, "Not read yet")
        }
        switch snapshot.health {
        case .ok: return (.green, "Connected")
        case .needsKeychainAccess: return (.orange, "Needs Keychain access")
        case .failed(let error): return (.red, error.summary)
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task { do { try await action(); error = nil } catch { self.error = "\(error)" } }
    }
}

struct ProxyEditor: View {
    @ObservedObject var model: AppModel
    let original: ProxyConfig
    let isNew: Bool
    let dismiss: () -> Void
    var initialTestResult: Result<[AccountDescriptor], ProxyAccessError>? = nil

    @State private var name = ""
    @State private var kind = ProxyKind.cliProxyAPI
    @State private var url = ""
    @State private var auth = ProxyAuth.managementKey
    @State private var secret = ""
    @State private var testResult: Result<[AccountDescriptor], ProxyAccessError>?
    @State private var testing = false
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Proxy" : "Edit Proxy").font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    field("Type") {
                        Picker("", selection: $kind) {
                            ForEach(ProxyKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .onChange(of: kind) { old, new in
                            if url.isEmpty || url == old.defaultBaseURL.absoluteString { url = new.defaultBaseURL.absoluteString }
                            if !validAuth(auth, for: new) { auth = .newDefault(for: new) }
                            testResult = nil
                        }
                    }
                    field("Name") { TextField("", text: $name, prompt: Text("e.g. vina2")) }
                    field("URL") { TextField("", text: $url, prompt: Text(kind.defaultBaseURL.absoluteString)) }
                    if kind == .nineRouter { authPicker }
                    field(secretLabel) {
                        SecureField("", text: $secret,
                                    prompt: Text(hasStoredSecret ? "Stored in Keychain — leave blank to keep" : "Stored in Keychain"))
                    }
                    help
                    if let problem = urlProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                    if let problem = secretProblem { Text(problem).font(.caption).foregroundStyle(.red) }
                    if needsNewSecret {
                        Text("Enter the secret again: the type, URL or sign-in changed.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let testResult { TestSummary(result: testResult) }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .frame(maxHeight: 340)
            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        perform { try await model.remove(original.id); dismiss() }
                    }
                    .disabled(saving)
                }
                Spacer()
                if testing || saving { ProgressView().controlSize(.small) }
                Button("Test") { runTest() }
                    .disabled(draft == nil || testing || saving || needsNewSecret || (isNew && auth.needsSecret && secret.isEmpty))
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft == nil || testing || saving || needsNewSecret || urlProblem != nil
                              || secretProblem != nil || (isNew && auth.needsSecret && secret.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear {
            name = original.name
            kind = original.kind
            url = original.baseURL.absoluteString
            auth = original.auth
            testResult = initialTestResult
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 76, alignment: .leading)
            content()
        }
    }

    private var authPicker: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Sign-in").font(.caption).foregroundStyle(.secondary)
            AuthOption(title: "CLI token (recommended)", selected: auth == .cliToken) {
                auth = .cliToken; testResult = nil
            }
            Text("Other sign-in").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                .padding(.leading, 22)
            AuthOption(title: "Dashboard password", selected: auth == .password) {
                auth = .password; testResult = nil
            }
        }
        .padding(.leading, 84)
    }

    @ViewBuilder private var help: some View {
        switch (kind, auth) {
        case (.cliProxyAPI, _):
            Text("Needs remote management enabled (management.allow-remote) for non-local URLs. Motas only reads; the proxy calls each provider's usage endpoint with the account's own token.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case (.nineRouter, .cliToken):
            VStack(alignment: .leading, spacing: 5) {
                Text("Permanent admin key for this 9Router. Motas only uses it for two read-only requests.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(ProxyAuth.cliTokenRecipe)
                    .font(.system(size: 9, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.05)))
                HStack(spacing: 6) {
                    Button("Copy recipe") { copy(ProxyAuth.cliTokenRecipe) }.controlSize(.mini)
                    Text("To rotate it, delete auth/cli-secret on the server.")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
        default:
            Text("Uses the dashboard login. Motas only reads accounts and their usage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hasStoredSecret: Bool { !isNew && model.hasSecret(for: original.id) }

    private var secretLabel: String {
        switch auth {
        case .managementKey: "Management key"
        case .cliToken: "CLI token"
        case .password: "Dashboard password"
        }
    }

    private func validAuth(_ auth: ProxyAuth, for kind: ProxyKind) -> Bool {
        kind == .cliProxyAPI ? auth == .managementKey : auth == .cliToken || auth == .password
    }

    /// The edited proxy, when the URL is valid.
    private var draft: ProxyConfig? {
        guard let parsed = ProxyConfig.baseURL(from: url) else { return nil }
        var config = original
        config.kind = kind
        config.auth = auth
        config.baseURL = parsed
        config.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (parsed.host ?? kind.displayName) : name
        return config
    }

    private var urlProblem: String? {
        ProxyConfig.baseURL(from: url) == nil
            ? "Enter an http(s) URL with a host, no credentials, query or fragment."
            : nil
    }

    private var secretProblem: String? {
        guard !secret.isEmpty else { return nil }
        return auth.problem(with: secret)
    }

    private var needsNewSecret: Bool {
        guard !isNew, let draft, secret.isEmpty else { return false }
        return AppModel.needsNewSecret(original, draft)
    }

    private func runTest() {
        guard let draft else { return }
        testing = true
        Task {
            testResult = await model.test(draft, secret: secret.isEmpty ? nil : secret)
            testing = false
        }
    }

    private func save() {
        guard let draft, !saving else { return }
        saving = true
        perform { try await model.save(draft, secret: secret.isEmpty ? nil : secret); dismiss() }
    }

    private func perform(_ action: @escaping () async throws -> Void) {
        Task {
            do {
                try await action()
                error = nil
            } catch {
                self.error = "\(error)"
                saving = false
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct AuthOption: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(title).font(.system(size: 11))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct TestSummary: View {
    let result: Result<[AccountDescriptor], ProxyAccessError>

    var body: some View {
        switch result {
        case .success(let accounts):
            Label(AccountDescriptor.summary(accounts), systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout).fixedSize(horizontal: false, vertical: true)
        case .failure(let error):
            Label(error.summary, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: General

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var notificationResult: String?
    @State private var error: String?

    private let intervals: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
    private let thresholds: [Double] = [0.05, 0.1, 0.2, 0.3, 0.5]

    var body: some View {
        Form {
            Picker("Refresh every", selection: binding(\.refreshInterval)) {
                ForEach(intervalOptions, id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
            }
            Picker("Warn below (default)", selection: binding(\.lowReserveThreshold)) {
                ForEach(thresholdOptions, id: \.self) { Text(Design.percent($0)).tag($0) }
            }
            Toggle("Notifications", isOn: binding(\.notificationsEnabled))
            HStack {
                Button("Send Test Notification") {
                    Task { notificationResult = await model.sendTestNotification().message }
                }
                if let notificationResult { Text(notificationResult).font(.caption).foregroundStyle(.secondary) }
            }
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchesAtLogin },
                set: { on in
                    do { try model.setLaunchAtLogin(on); error = nil }
                    catch { self.error = "Launch at login needs the installed Motas.app." }
                }
            ))
            Picker("Menu bar", selection: Binding<String?>(
                get: { model.menuBarPool },
                set: { model.menuBarPool = $0 }
            )) {
                Text("Automatic").tag(String?.none)
                ForEach(poolIDs, id: \.self) { id in
                    Text(poolName(id)).tag(String?.some(id))
                }
            }
            Toggle("Show Model Pulse on desktop", isOn: $model.desktopWidgetEnabled)
            HStack {
                Toggle("Lock desktop widget position", isOn: $model.desktopWidgetLocked)
                    .disabled(!model.desktopWidgetEnabled)
                Spacer()
                Button("Reset Position") {
                    NotificationCenter.default.post(name: .motasResetDesktopWidgetPosition, object: nil)
                }
                .controlSize(.small)
                .disabled(!model.desktopWidgetEnabled)
                .help("Move Model Pulse back to its default corner")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
    }

    private var intervalOptions: [TimeInterval] {
        let current = model.settings.clampedRefreshInterval
        return Array(Set(intervals + [current])).sorted()
    }

    private var thresholdOptions: [Double] {
        let current = model.settings.lowReserveThreshold
        return Array(Set(thresholds + [current])).sorted()
    }

    private var poolIDs: [String] {
        var ids = model.pools.map(\.id)
        if let pinned = model.menuBarPool, !ids.contains(pinned) { ids.append(pinned) }
        return ids
    }

    private func poolName(_ id: String) -> String {
        model.pools.first { $0.id == id }?.displayName ?? "\(id) (missing)"
    }

    private func binding<T>(_ keyPath: WritableKeyPath<MotasSettings, T>) -> Binding<T> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in
                do { try model.update { $0[keyPath: keyPath] = value }; error = nil } catch { self.error = "\(error)" }
            }
        )
    }
}

// MARK: Quotas

/// Every pool's own choices: the same as its card's ⋯ menu in the panel.
struct QuotasTab: View {
    @ObservedObject var model: AppModel

    private var pools: [PoolSummary] { model.pools + model.hiddenPools }

    var body: some View {
        Form {
            if pools.isEmpty {
                Text("Quotas appear here after the first refresh.").foregroundStyle(.secondary)
            }
            ForEach(pools) { pool in
                Section {
                    row(pool)
                } header: {
                    HStack {
                        Text(pool.displayName)
                        Spacer()
                        Text(pool.reserve.map(Design.percent) ?? "—").monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func row(_ pool: PoolSummary) -> some View {
        let options = model.settings.options(for: pool.id)
        let lanes = pool.lanes.filter { $0.id != "models" }
        Picker("Warn below", selection: Binding<Double?>(
            get: { options.lowReserveThreshold },
            set: { level in model.setOptions(for: pool.id) { $0.lowReserveThreshold = level } })) {
            Text("Default (\(Design.percent(model.settings.lowReserveThreshold)))").tag(Double?.none)
            ForEach(PoolOptionsMenu.levels, id: \.self) { Text(Design.percent($0)).tag(Double?.some($0)) }
        }
        if lanes.count > 1 {
            Picker("Percentage from", selection: Binding<String?>(
                get: { options.basis },
                set: { basis in model.setOptions(for: pool.id) { $0.basis = basis } })) {
                Text("Lowest window").tag(String?.none)
                ForEach(lanes) { Text("\($0.label) window").tag(String?.some($0.id)) }
            }
        }
        Toggle("Notifications", isOn: Binding(
            get: { options.notify },
            set: { on in model.setOptions(for: pool.id) { $0.notify = on } }))
        Toggle("Show in panel, menu bar and desktop", isOn: Binding(
            get: { !options.hidden },
            set: { shown in
                if !shown, model.menuBarPool == pool.id { model.menuBarPool = nil }
                model.setOptions(for: pool.id) { $0.hidden = !shown }
            }))
    }
}
