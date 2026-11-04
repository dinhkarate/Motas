import AppKit
import SwiftUI
import UserNotifications

public struct MotasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            PanelView(model: delegate.model)
        } label: {
            MenuBarLabel(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        // Plain windows rather than the `Settings` scene: SettingsLink does not
        // reliably come to front from an accessory (menu bar only) app.
        Window("Motas Settings", id: "settings") {
            SettingsView(model: delegate.model)
        }
        .windowResizability(.contentSize)

        Window("Motas History", id: "history") {
            HistoryView(model: delegate.model)
        }
    }
}

/// Owns the one `AppModel`, so there is never a second model, timer or Monitor.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if Bundle.main.isAppBundle { UNUserNotificationCenter.current().delegate = self }
        model.start()
    }

    /// Banners show even while Motas is active (its panel or Settings open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await open(response.notification.request.content.userInfo as? [String: String] ?? [:])
    }

    private func open(_ userInfo: [String: String]) {
        switch AlertClick(userInfo, proxies: model.settings.proxies) {
        case .dashboard(let url):
            NSWorkspace.shared.open(url)
        case .panel:
            // Best effort: click the menu-bar item, else just come to the front.
            if let button = NSApplication.shared.windows.lazy.compactMap({ $0.contentView.flatMap { Self.statusButton(in: $0) } }).first {
                button.performClick(nil)
            } else {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
    }

    private static func statusButton(in view: NSView) -> NSStatusBarButton? {
        view as? NSStatusBarButton ?? view.subviews.lazy.compactMap { statusButton(in: $0) }.first
    }
}
