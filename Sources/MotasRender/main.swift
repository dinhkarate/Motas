// Development tool: renders Motas views to PNG from a live refresh, without
// screen-recording permission (offscreen NSWindow + cacheDisplay).
//
//   MOTAS_CPA_URL=… MOTAS_CPA_KEY=… MOTAS_9R_URL=… MOTAS_9R_PASSWORD=… \
//     swift run motas-render /tmp/motas-render
import AppKit
import MotasCore
@testable import MotasUI
import MotasWidgetKit
import SwiftUI
import WidgetKit

@MainActor
func render<V: View>(_ view: V, _ name: String, to dir: URL, dark: Bool, expanded: Bool = false) {
    let background = dark ? Color(white: 0.16) : Color(white: 0.97)
    let hosting = NSHostingView(rootView: view.environment(\.motasExpandGroups, expanded).background(background))
    hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let size = hosting.fittingSize
    hosting.frame = NSRect(origin: .zero, size: size)
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
    print("wrote \(url.path) \(Int(size.width))x\(Int(size.height))")
}

@MainActor
func run() async {
    let env = ProcessInfo.processInfo.environment
    let out = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/motas-render")
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("motas-render-\(UUID().uuidString)")
    let paths = AppModel.Paths(settings: tmp.appendingPathComponent("settings.json"),
                               history: tmp.appendingPathComponent("history.json"),
                               snapshot: tmp.appendingPathComponent("snapshot.json"))

    let empty = AppModel(paths: paths, secrets: InMemorySecretStore(), autoRefresh: false)
    for dark in [false, true] { render(PanelView(model: empty), "panel-empty", to: out, dark: dark) }

    let model = AppModel(paths: paths, secrets: InMemorySecretStore(), autoRefresh: false)
    if let cpa = env["MOTAS_CPA_URL"].flatMap(URL.init(string:)) {
        try? model.save(ProxyConfig(name: "obsession CPA", kind: .cliProxyAPI, baseURL: cpa), secret: env["MOTAS_CPA_KEY"])
    }
    if let nine = env["MOTAS_9R_URL"].flatMap(URL.init(string:)) {
        try? model.save(ProxyConfig(name: "obsession 9Router", kind: .nineRouter, baseURL: nine), secret: env["MOTAS_9R_PASSWORD"])
    }
    await model.refresh()
    for dark in [false, true] {
        render(PanelView(model: model), "panel", to: out, dark: dark)
        render(PanelView(model: model), "panel-expanded", to: out, dark: dark, expanded: true)
        render(MenuBarLabel(model: model).padding(4), "menubar", to: out, dark: dark)
        render(SettingsView(model: model), "settings", to: out, dark: dark)
        render(HistoryView(model: model), "history", to: out, dark: dark)
    }
    let entry = PoolEntry(date: .now, pools: model.pools, fetchedAt: model.snapshot.fetchedAt,
                          threshold: model.settings.lowReserveThreshold, problem: nil)
    for dark in [false, true] {
        render(PoolWidgetView(entry: entry, family: .systemSmall).padding(16).frame(width: 170, height: 170), "widget-small", to: out, dark: dark)
        render(PoolWidgetView(entry: entry, family: .systemMedium).padding(16).frame(width: 364, height: 170),
               "widget-medium", to: out, dark: dark)
    }
    if let first = model.settings.proxies.first {
        let editor = ProxyEditor(model: model, original: first, isNew: false, dismiss: {},
                                 initialTestResult: model.snapshot.proxies.first)
        render(editor, "editor", to: out, dark: false)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    await run()
    exit(0)
}
app.run()
