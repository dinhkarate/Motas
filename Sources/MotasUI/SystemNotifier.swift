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
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .notBundled }
        let center = UNUserNotificationCenter.current()
        center.delegate = PresentInForeground.shared
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return .denied }
            for alert in alerts {
                let content = UNMutableNotificationContent()
                content.title = alert.title
                content.body = alert.body
                content.sound = .default
                try await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
            }
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// Shows banners even while Motas is the active app (its panel or Settings is open).
final class PresentInForeground: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = PresentInForeground()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
