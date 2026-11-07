import AppKit
import Foundation
import UserNotifications

public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()

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

    public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
