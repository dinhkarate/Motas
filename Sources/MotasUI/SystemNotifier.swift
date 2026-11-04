import Foundation
import MotasCore
import UserNotifications

public enum NotificationDelivery: Equatable, Sendable {
    case delivered
    /// Not running from Motas.app (e.g. `swift run`): Notification Center needs a bundle.
    case notBundled
    /// The user turned notifications off for Motas.
    case denied
    case failed(String)

    public var message: String {
        switch self {
        case .delivered: "Sent. If no banner appeared, check Notification Center."
        case .notBundled: "Notifications need the installed Motas.app."
        case .denied: "Notifications are off for Motas. Turn them on in System Settings › Notifications."
        case .failed(let reason): "Could not send: \(reason)"
        }
    }
}

/// Delivers alerts through Notification Center. Requires a real app bundle;
/// unbundled runs skip delivery instead of crashing.
public struct SystemNotifier: Notifier {
    public init() {}

    @discardableResult
    public func deliver(_ alerts: [QuotaAlert]) async -> NotificationDelivery {
        guard Bundle.main.isAppBundle else { return .notBundled }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return .denied }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.sound = .default
                content.userInfo = Self.userInfo(alert)
                try await center.add(UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil))
            }
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// What a click needs: the kind, and the pool or proxy when there is one.
    static func userInfo(_ alert: QuotaAlert) -> [String: String] {
        var info = ["kind": alert.kind.rawValue]
        info["poolID"] = alert.poolID
        info["proxyID"] = alert.proxyID?.uuidString
        return info
    }
}

/// What clicking a notification opens.
enum AlertClick: Equatable {
    /// The proxy's dashboard, for proxy-down and accounts-rejected.
    case dashboard(URL)
    /// The menu-bar panel, for anything else.
    case panel

    init(_ userInfo: [String: String], proxies: [ProxyConfig]) {
        let kind = userInfo["kind"].flatMap(QuotaAlert.Kind.init(rawValue:))
        let id = userInfo["proxyID"].flatMap(UUID.init(uuidString:))
        if kind == .proxyDown || kind == .accountsRejected, let proxy = proxies.first(where: { $0.id == id }) {
            self = .dashboard(proxy.dashboardURL)
        } else {
            self = .panel
        }
    }
}
