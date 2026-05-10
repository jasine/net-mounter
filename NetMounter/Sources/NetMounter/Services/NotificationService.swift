import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.netmounter.app", category: "Notification")

class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private static let retryActionID = "RETRY_MOUNT"
    private static let categoryWithRetry = "MOUNT_FAILURE"

    private var center: UNUserNotificationCenter?
    var onRetry: ((UUID) -> Void)?

    override init() {
        super.init()
    }

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else {
            logger.warning("No bundle identifier — notifications disabled")
            return
        }

        let notificationCenter = UNUserNotificationCenter.current()
        self.center = notificationCenter

        let retryAction = UNNotificationAction(
            identifier: Self.retryActionID,
            title: String(localized: "Retry"),
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.categoryWithRetry,
            actions: [retryAction],
            intentIdentifiers: []
        )
        notificationCenter.setNotificationCategories([category])
        notificationCenter.delegate = self

        notificationCenter.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error = error {
                logger.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
            } else if !granted {
                logger.info("Notification permission denied by user")
            }
        }
    }

    // MARK: - Notification Events

    func notifyMountFailed(server: ServerConfig) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Mount Failed")
        content.body = String(localized: "\(server.alias) failed after 5 retries")
        content.sound = .default
        content.categoryIdentifier = Self.categoryWithRetry
        content.userInfo = ["serverID": server.id.uuidString]
        send(id: "mount-failed-\(server.id)", content: content)
    }

    func notifyZombieHealed(server: ServerConfig) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Connection Restored")
        content.body = String(localized: "\(server.alias) recovered from unresponsive state")
        content.sound = .default
        send(id: "zombie-healed-\(server.id)", content: content)
    }

    func notifyWakeReconnected(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Connections Restored")
        content.body = String(localized: "Restored \(count) network drive(s) after wake")
        content.sound = .default
        send(id: "wake-reconnected", content: content)
    }

    func notifyWakeReconnectFailed(count: Int) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Reconnect Failed")
        content.body = String(localized: "\(count) drive(s) not restored after wake")
        content.sound = .default
        content.categoryIdentifier = Self.categoryWithRetry
        send(id: "wake-reconnect-failed", content: content)
    }

    private func send(id: String, content: UNMutableNotificationContent) {
        guard let center = center else { return }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        center.add(request) { error in
            if let error = error {
                logger.error("Failed to send notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == Self.retryActionID,
           let idString = response.notification.request.content.userInfo["serverID"] as? String,
           let serverID = UUID(uuidString: idString) {
            onRetry?(serverID)
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
