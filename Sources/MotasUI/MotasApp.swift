import AppKit
import SwiftUI

public struct MotasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            PanelView(model: model)
        } label: {
            MenuBarLabel(model: model)
                .task { model.start() }
        }
        .menuBarExtraStyle(.window)

        // Plain windows rather than the `Settings` scene: SettingsLink does not
        // reliably come to front from an accessory (menu bar only) app.
        Window("Motas Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)

        Window("Motas History", id: "history") {
            HistoryView(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}
