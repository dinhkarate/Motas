import Foundation
import MotasCore
import UserNotifications

/// Delivers alerts through Notification Center. Requires a real app bundle;
/// unbundled runs (`swift run`) skip delivery instead of crashing.
public struct SystemNotifier: Notifier {
    public init() {}

    public func deliver(_ alerts: [QuotaAlert]) async {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
