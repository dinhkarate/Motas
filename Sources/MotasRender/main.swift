// Development tool: renders Motas views to PNG, without screen-recording
// permission (offscreen NSWindow + cacheDisplay).
//
//   swift run motas-render [--live] [output dir]
//
// Offline (the default) builds the production 9Router capture through the real
// adapter and a fixture HTTP client. Live needs MOTAS_9R_URL and
// MOTAS_9R_TOKEN (or MOTAS_9R_PASSWORD); run it through `keyshroud`.
import AppKit
import MotasCore
@testable import MotasUI
import MotasWidgetKit
import SwiftUI
import WidgetKit

@MainActor
func render<V: View>(_ view: V, _ name: String, to dir: URL, dark: Bool, expanded: Bool = false,
                     size: CGSize? = nil) {
    let background = dark ? Color(white: 0.16) : Color(white: 0.97)
    var root = AnyView(view.environment(\.motasExpandGroups, expanded))
    if let size { root = AnyView(root.frame(width: size.width, height: size.height)) }
    root = AnyView(root.background(background))
    let hosting = NSHostingView(rootView: root)
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    // AppKit-backed controls (tab bar, pickers) read NSApp's appearance.
    NSApp.appearance = hosting.appearance
    let fitting = size ?? hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: fitting)
    let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = hosting.appearance
    window.backgroundColor = dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    window.contentView = hosting
    hosting.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
    hosting.cacheDisplay(in: hosting.bounds, to: rep)
    let url = dir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
    try? rep.representation(using: .png, properties: [:])?.write(to: url)
    print("wrote \(url.path) \(Int(fitting.width))x\(Int(fitting.height))")
}

/// The captured production 9Router, served from the test fixtures.
struct FixtureHTTP: HTTPClient {
    let dir: URL

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        let status: Int
        let body: Data
        switch path {
        case "/api/providers":
            status = 200
            body = try Data(contentsOf: dir.appendingPathComponent("9r_prod_providers.json"))
        case let p where p.hasPrefix("/api/usage/"):
            let byID = try JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("9r_prod_usage_by_connection.json"))) as? [String: [String: Any]]
            guard let reply = byID?[String(p.dropFirst("/api/usage/".count))] else {
                throw URLError(.fileDoesNotExist)
            }
            status = reply["status"] as? Int ?? 500
            body = try JSONSerialization.data(withJSONObject: reply["body"] ?? [:])
        default:
            status = 404
            body = Data()
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct RenderNotifier: Notifier {
    func deliver(_ alerts: [QuotaAlert]) async -> NotificationDelivery { .delivered }
}

/// When the production capture was taken: 2026-11-02T16:10:30Z.
let productionNow = Date(timeIntervalSince1970: 1_793_635_830)

@MainActor
func makeModel(http: any HTTPClient, now: @escaping @Sendable () -> Date,
               seedHistory: [PoolSample] = []) -> AppModel {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("motas-render-\(UUID().uuidString)")
    let historyURL = tmp.appendingPathComponent("history.json")
    if !seedHistory.isEmpty {
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(seedHistory).write(to: historyURL, options: .atomic)
    }
    let paths = AppModel.Paths(settings: tmp.appendingPathComponent("settings.json"),
                               history: historyURL,
                               snapshot: tmp.appendingPathComponent("snapshot.json"))
    let defaults = UserDefaults(suiteName: tmp.appendingPathComponent("preferences").path)!
    return AppModel(AppEnvironment(paths: paths, secrets: InMemorySecretStore(), http: http, notifier: RenderNotifier(),
                                   preferences: UIPreferences(defaults: defaults), now: now))
}

/// A week of plausible samples for the three production pools, so the history
/// chart has lines to draw. Render-only fixture data.
func renderHistory(now: Date) -> [PoolSample] {
    let pools: [(id: String, from: Double, to: Double)] = [
        ("codex|free|", 0.78, 0.513),
        ("antigravity||gemini", 1.0, 0.992),
        ("antigravity||claude-gpt", 1.0, 1.0),
    ]
    return (0..<7).flatMap { day in
        let t = Double(day) / 6
        return pools.map { pool in
            let drift = pool.from + (pool.to - pool.from) * t
            let wiggle = sin(Double(day) * 1.7) * 0.012
            return PoolSample(at: now.addingTimeInterval(Double(day - 6) * 86_400),
                              pool: pool.id, reserve: min(1, max(0.01, drift + wiggle)))
        }
    }
}

@MainActor
func run() async {
    let args = CommandLine.arguments.dropFirst()
    let live = args.contains("--live")
    let out = URL(fileURLWithPath: args.first { !$0.hasPrefix("--") } ?? "/tmp/motas-render")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let empty = makeModel(http: URLSessionHTTPClient(), now: Date.init)
    for dark in [false, true] { render(PanelView(model: empty), "panel-empty", to: out, dark: dark) }

    let model: AppModel
    if live {
        guard let url = ProcessInfo.processInfo.environment["MOTAS_9R_URL"].flatMap(URL.init(string:)) else {
            print("--live needs MOTAS_9R_URL and MOTAS_9R_TOKEN (or MOTAS_9R_PASSWORD)")
            return
        }
        let env = ProcessInfo.processInfo.environment
        let auth: ProxyAuth = env["MOTAS_9R_TOKEN"] != nil ? .cliToken : .password
        let secret = env["MOTAS_9R_TOKEN"] ?? env["MOTAS_9R_PASSWORD"]
        model = makeModel(http: URLSessionHTTPClient(), now: Date.init)
        try? await model.save(ProxyConfig(name: "9Router", kind: .nineRouter, baseURL: url, auth: auth), secret: secret)
        await model.refresh(force: true, reason: "render").value
    } else {
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Tests/MotasCoreTests/Fixtures/live")
        guard FileManager.default.fileExists(atPath: fixtures.appendingPathComponent("9r_prod_providers.json").path) else {
            print("fixtures not found at \(fixtures.path)")
            return
        }
        model = makeModel(http: FixtureHTTP(dir: fixtures), now: { productionNow },
                          seedHistory: renderHistory(now: productionNow))
        let config = ProxyConfig(name: "Production 9Router", kind: .nineRouter,
                                 baseURL: URL(string: "https://router.example.com")!, auth: .cliToken)
        try? await model.save(config, secret: "0123456789abcdef")
        // Two reads: the second confirms rejected credentials, as a relaunch would.
        await model.refresh(force: true, reason: "render").value
        await model.refresh(force: true, reason: "render").value
    }

    for dark in [false, true] {
        model.onboardingDone = false
        render(PanelView(model: model), "first-run", to: out, dark: dark)
        model.onboardingDone = true
        render(PanelView(model: model), "panel", to: out, dark: dark)
        render(PanelView(model: model), "panel-expanded", to: out, dark: dark, expanded: true)
        render(MenuBarLabel(model: model).padding(4), "menubar", to: out, dark: dark)
        render(SettingsView(model: model), "settings", to: out, dark: dark, size: CGSize(width: 560, height: 420))
        render(ProxiesTab(model: model), "settings-proxies", to: out, dark: dark, size: CGSize(width: 560, height: 420))
        render(GeneralTab(model: model), "settings-general", to: out, dark: dark, size: CGSize(width: 560, height: 420))
        render(HistoryView(model: model), "history", to: out, dark: dark)
    }

    if let first = model.settings.proxies.first {
        let editor = ProxyEditor(model: model, original: first, isNew: false, dismiss: {},
                                 initialTestResult: await model.test(first, secret: nil))
        for dark in [false, true] { render(editor, "editor", to: out, dark: dark, size: CGSize(width: 500, height: 560)) }
    }

    let entry = PoolEntry(date: model.now, headline: model.headline, pools: model.pools, fetchedAt: model.snapshot.fetchedAt,
                          threshold: model.settings.lowReserveThreshold, problem: nil)
    for dark in [false, true] {
        render(PoolWidgetView(entry: entry, family: .systemSmall).padding(16).frame(width: 170, height: 170),
               "widget-small", to: out, dark: dark)
        render(PoolWidgetView(entry: entry, family: .systemMedium).padding(16).frame(width: 364, height: 170),
               "widget-medium", to: out, dark: dark)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
app.run()
