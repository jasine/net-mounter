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

    func notifyMountSucceeded(server: ServerConfig) {
        send(id: "mount-succeeded-\(server.id)",
             title: String(localized: "Mount Succeeded"),
             body: String(localized: "\(server.alias) is now connected"))
    }

    func notifyMountFailed(server: ServerConfig, retries: Int = 5) {
        send(id: "mount-failed-\(server.id)",
             title: String(localized: "Mount Failed"),
             body: String(localized: "\(server.alias) failed after \(retries) retries"),
             category: Self.categoryWithRetry,
             userInfo: ["serverID": server.id.uuidString])
    }

    func notifyZombieHealed(server: ServerConfig) {
        send(id: "zombie-healed-\(server.id)",
             title: String(localized: "Connection Restored"),
             body: String(localized: "\(server.alias) recovered from unresponsive state"))
    }

    func notifyWakeReconnected(count: Int) {
        send(id: "wake-reconnected",
             title: String(localized: "Connections Restored"),
             body: String(localized: "Restored \(count) network drive(s) after wake"))
    }

    func notifyWakeReconnectFailed(count: Int) {
        send(id: "wake-reconnect-failed",
             title: String(localized: "Reconnect Failed"),
             body: String(localized: "\(count) drive(s) not restored after wake"),
             category: Self.categoryWithRetry)
    }

    private func send(id: String, title: String, body: String, category: String? = nil, userInfo: [String: String]? = nil) {
        guard let center = center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let category = category { content.categoryIdentifier = category }
        if let userInfo = userInfo { content.userInfo = userInfo }
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
