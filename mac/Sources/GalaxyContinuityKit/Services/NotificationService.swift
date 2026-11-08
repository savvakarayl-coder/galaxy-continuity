import AppKit
import Foundation
import UserNotifications

public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

    public static let CATEGORY_REPLY = "GALAXY_NOTIFICATION_REPLY_CATEGORY"
    public static let ACTION_REPLY = "GALAXY_REPLY_ACTION"

    /// Test / Headless interception callback
    public var onReplyDispatched: ((_ id: String, _ packageName: String, _ text: String) -> Void)?

    /// Callback when user clicks on a notification banner (default action)
    public var onNotificationClicked: ((_ id: String, _ packageName: String) -> Void)?

    /// Test helper alias for notification open callback
    public var onNotificationOpened: ((_ id: String, _ packageName: String) -> Void)? {
        get { onNotificationClicked }
        set { onNotificationClicked = newValue }
    }

    public func dispatchNotificationOpen(id: String, packageName: String) {
        onNotificationClicked?(id, packageName)
    }

    /// Indicates whether UNUserNotificationCenter is available in the current execution context.
    /// Standalone command-line executables and unit test runners lack an application bundle identifier
    /// (`Bundle.main.bundleIdentifier == nil`), causing `UNUserNotificationCenter.current()` to throw
    /// an uncaught NSInternalInconsistencyException.
    public var isAvailable: Bool {
        return Bundle.main.bundleIdentifier != nil
    }

    private override init() {
        super.init()
        setup()
    }

    private func setup() {
        guard isAvailable else {
            print("[NotificationService] Running outside application bundle (headless/CLI mode). UserNotifications suppressed.")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("[NotificationService] Authorization error: \(error)")
            }
        }

        // Register interactive quick reply action & category
        let replyAction = UNTextInputNotificationAction(
            identifier: NotificationService.ACTION_REPLY,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a reply..."
        )
        let replyCategory = UNNotificationCategory(
            identifier: NotificationService.CATEGORY_REPLY,
            actions: [replyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([replyCategory])
    }

    public func showNotification(title: String, subtitle: String? = nil, body: String, sound: Bool = true) {
        guard isAvailable else {
            let subText = subtitle.map { " (\($0))" } ?? ""
            print("[NotificationService] [Headless] \(title)\(subText): \(body)")
            if sound {
                DispatchQueue.main.async {
                    NSSound(named: "Glass")?.play()
                }
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle = subtitle {
            content.subtitle = subtitle
        }
        content.body = body
        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationService] Error delivering notification: \(error)")
            }
        }

        if sound {
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
            }
        }
    }

    public func showPhoneNotification(
        id: String,
        packageName: String,
        appName: String,
        title: String,
        body: String,
        canReply: Bool,
        sound: Bool = true
    ) {
        guard isAvailable else {
            print("[NotificationService] [Headless] 📱 [\(appName)] \(title): \(body) (canReply: \(canReply), id: \(id))")
            if sound {
                DispatchQueue.main.async {
                    NSSound(named: "Glass")?.play()
                }
            }
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "📱 \(title)"
        content.subtitle = "via \(appName)"
        content.body = body
        content.userInfo = [
            "notifId": id,
            "packageName": packageName
        ]

        if canReply {
            content.categoryIdentifier = NotificationService.CATEGORY_REPLY
        }

        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: id.isEmpty ? UUID().uuidString : id,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("[NotificationService] Error delivering phone notification: \(error)")
            }
        }

        if sound {
            DispatchQueue.main.async {
                NSSound(named: "Glass")?.play()
            }
        }
    }

    public func dispatchReply(id: String, packageName: String, text: String) {
        onReplyDispatched?(id, packageName, text)
        ServerManager.shared.sendNotificationReply(id: id, packageName: packageName, replyText: text)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let notifId = userInfo["notifId"] as? String ?? ""
        let packageName = userInfo["packageName"] as? String ?? ""

        if response.actionIdentifier == NotificationService.ACTION_REPLY,
           let textResponse = response as? UNTextInputNotificationResponse {
            let replyText = textResponse.userText
            if !notifId.isEmpty && !replyText.isEmpty {
                dispatchReply(id: notifId, packageName: packageName, text: replyText)
            }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            if !packageName.isEmpty || !notifId.isEmpty {
                DispatchQueue.main.async { [weak self] in
                    self?.onNotificationClicked?(notifId, packageName)
                }
            }
        }
        completionHandler()
    }
}
