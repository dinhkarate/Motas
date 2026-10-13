import MotasCore
import ServiceManagement
import SwiftUI

public struct SettingsView: View {
    @ObservedObject var model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        TabView {
            ProxiesTab(model: model).tabItem { Label("Proxies", systemImage: "server.rack") }
            GeneralTab(model: model).tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 420)
        .padding(.top, 8)
        .environment(\.locale, Format.locale)
    }
}

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
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { proxy.isEnabled },
                                set: { on in perform { var p = proxy; p.isEnabled = on; try model.save(p, secret: nil) } }
                            ))
                            .labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            VStack(alignment: .leading) {
                                Text(proxy.name)
                                Text("\(proxy.kind.displayName) · \(proxy.baseURL.absoluteString)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit…") { isNew = false; editing = proxy }
                        }
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

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = "\(error)" }
    }
}

struct ProxyEditor: View {
    @ObservedObject var model: AppModel
    let original: ProxyConfig
    let isNew: Bool
    let dismiss: () -> Void
    var initialTestResult: ProxySnapshot? = nil

    @State private var name = ""
    @State private var kind = ProxyKind.cliProxyAPI
    @State private var url = ""
    @State private var secret = ""
    @State private var testResult: ProxySnapshot?
    @State private var testing = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Add Proxy" : "Edit Proxy").font(.headline)
            Form {
                Picker("Type", selection: $kind) {
                    ForEach(ProxyKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                .onChange(of: kind) { old, new in
                    if url.isEmpty || url == old.defaultBaseURL.absoluteString { url = new.defaultBaseURL.absoluteString }
                    testResult = nil
                }
                TextField("Name", text: $name, prompt: Text("e.g. vina2"))
                TextField("URL", text: $url, prompt: Text(kind.defaultBaseURL.absoluteString))
                SecureField(kind == .cliProxyAPI ? "Management key" : "Dashboard password", text: $secret,
                            prompt: Text(hasStoredSecret ? "Stored in Keychain — leave blank to keep" : "Stored in Keychain"))
            }
            Text(kind == .cliProxyAPI
                 ? "Needs remote management enabled (management.allow-remote) for non-local URLs. Motas only reads; the proxy calls each provider's usage endpoint with the account's own token."
                 : "Uses the dashboard login. Motas only reads accounts and their usage.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            if let testResult { TestSummary(result: testResult) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }

            HStack {
                if !isNew {
                    Button("Delete", role: .destructive) {
                        perform { try model.remove(original.id); dismiss() }
                    }
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Test") { runTest() }.disabled(draft == nil || testing)
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let draft else { return }
                    perform { try model.save(draft, secret: secret.isEmpty ? nil : secret); dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            name = original.name
            kind = original.kind
            url = original.baseURL.absoluteString
            testResult = initialTestResult
        }
    }

    private var hasStoredSecret: Bool { !isNew && model.hasSecret(for: original.id) }

    /// Valid http(s) URL with a host; no credentials, query or fragment.
    private var draft: ProxyConfig? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard let parsed = URL(string: trimmed), ["http", "https"].contains(parsed.scheme?.lowercased() ?? ""),
              parsed.host?.isEmpty == false, parsed.user == nil, parsed.password == nil,
              parsed.query == nil, parsed.fragment == nil else { return nil }
        var config = original
        config.kind = kind
        config.baseURL = parsed
        config.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? (parsed.host ?? kind.displayName) : name
        return config
    }

    private func runTest() {
        guard let draft else { return }
        testing = true
        Task {
            testResult = await model.test(draft, secret: secret.isEmpty ? nil : secret)
            testing = false
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); error = nil } catch { self.error = "\(error)" }
    }
}

struct TestSummary: View {
    let result: ProxySnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if result.health.isOK {
                Label("Connected — \(Format.count(result.accounts.count, "account"))", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                let byProvider = Dictionary(grouping: result.accounts) { $0.provider }.sorted { $0.key < $1.key }
                ForEach(byProvider, id: \.0) { provider, accounts in
                    let measured = accounts.filter { !$0.quota.windows.isEmpty }.count
                    Text("\(provider.displayName): \(Format.count(accounts.count, "account")), \(measured) with quota figures")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(result.health.summary, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }
}

struct GeneralTab: View {
    @ObservedObject var model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    private let intervals: [TimeInterval] = [60, 120, 300, 600, 900, 1800, 3600]
    private let thresholds: [Double] = [0.1, 0.2, 0.3, 0.5]

    var body: some View {
        Form {
            Picker("Refresh every", selection: binding(\.refreshInterval)) {
                ForEach(intervals, id: \.self) { Text("\(Int($0 / 60)) min").tag($0) }
            }
            Picker("Warn below", selection: binding(\.lowReserveThreshold)) {
                ForEach(thresholds, id: \.self) { Text(Format.percent($0)).tag($0) }
            }
            Toggle("Notifications", isOn: binding(\.notificationsEnabled))
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        error = nil
                    } catch {
                        self.error = "Launch at login needs the installed Motas.app."
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .formStyle(.grouped)
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
