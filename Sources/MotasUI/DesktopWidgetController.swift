import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Settings' "Reset Position" button.
    static let motasResetDesktopWidgetPosition = Notification.Name("dev.motas.desktop-widget.reset-position")
    /// The widget's "Open Motas Settings"; the menu bar label opens the window.
    static let motasOpenSettings = Notification.Name("dev.motas.open-settings")
}

/// Owns Model Pulse: one borderless panel at desktop-icon level. It is shown
/// and hidden with `desktopWidget.enabled` and never closed.
@MainActor
final class DesktopWidgetController {
    private let model: AppModel
    private let panel: DesktopPanel
    private let autosaveName = "MotasModelPulse"
    private var subscriptions: Set<AnyCancellable> = []

    init(model: AppModel) {
        self.model = model
        let panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.title = "Model Pulse"
        panel.isMovableByWindowBackground = !model.desktopWidgetLocked

        let hosting = NSHostingView(rootView: DesktopWidgetView(model: model))
        hosting.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = hosting
        self.panel = panel

        panel.menuProvider = { [weak self] in self?.menu() ?? NSMenu() }
        sizeToFit()
        if !panel.setFrameUsingName(autosaveName) {
            panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
        }
        panel.setFrameAutosaveName(autosaveName)
        sizeToFit()
        observe()
    }

    // MARK: Visibility

    private func observe() {
        model.$desktopWidgetEnabled
            .combineLatest(model.$desktopWidgetLocked)
            .sink { [weak self] pair in
                Task { @MainActor in self?.apply(enabled: pair.0, locked: pair.1) }
            }
            .store(in: &subscriptions)

        model.$pools.map { _ in () }
            .merge(with: model.$desktopWidgetCards.map { _ in () })
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.sizeToFit()
                    self?.clampToScreen()
                }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.clampToScreen() }
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .motasResetDesktopWidgetPosition)
            .sink { [weak self] _ in
                Task { @MainActor in self?.resetPosition() }
            }
            .store(in: &subscriptions)
    }

    private func apply(enabled: Bool, locked: Bool) {
        panel.isMovableByWindowBackground = !locked
        guard enabled else {
            panel.orderOut(nil)
            return
        }
        sizeToFit()
        clampToScreen()
        panel.orderFront(nil)
    }

    // MARK: Placement

    /// The panel's top edge stays put when the card count changes.
    private func sizeToFit() {
        guard let view = panel.contentView else { return }
        view.layoutSubtreeIfNeeded()
        let height = view.fittingSize.height
        guard height > 0, abs(panel.frame.height - height) > 0.5 else { return }
        let top = panel.frame.maxY
        panel.setContentSize(NSSize(width: 340, height: height))
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
    }

    private func clampToScreen() {
        guard let screen = panel.screen
            ?? NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var frame = panel.frame
        frame.origin.x = min(max(frame.minX, visible.minX), max(visible.minX, visible.maxX - frame.width))
        frame.origin.y = min(max(frame.minY, visible.minY), max(visible.minY, visible.maxY - frame.height))
        if frame.origin != panel.frame.origin { panel.setFrameOrigin(frame.origin) }
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: visible.minX + 30, y: visible.maxY - 300 - size.height)
    }

    private func resetPosition() {
        panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
        panel.saveFrame(usingName: autosaveName)
        clampToScreen()
    }

    // MARK: Menu

    private func menu() -> NSMenu {
        let menu = NSMenu()
        let lock = NSMenuItem(title: "Lock position", action: #selector(toggleLock), keyEquivalent: "")
        lock.target = self
        lock.state = model.desktopWidgetLocked ? .on : .off
        menu.addItem(lock)
        let hide = NSMenuItem(title: "Hide", action: #selector(hide), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Open Motas Settings", action: #selector(openSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        return menu
    }

    @objc private func toggleLock() { model.desktopWidgetLocked.toggle() }
    @objc private func hide() { model.desktopWidgetEnabled = false }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: {
            $0.title == "Motas Settings" || $0.identifier?.rawValue == "settings"
        }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .motasOpenSettings, object: nil)
        }
    }
}

/// A nonactivating panel that never takes focus; a right-click opens the
/// controller's menu before the content view sees the event.
@MainActor
private final class DesktopPanel: NSPanel {
    var menuProvider: (() -> NSMenu)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .rightMouseDown, let view = contentView, let menu = menuProvider?() {
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return
        }
        super.sendEvent(event)
    }
}
