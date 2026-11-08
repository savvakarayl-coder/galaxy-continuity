import Foundation
import Testing
@testable import GalaxyContinuityKit

@Suite("Notification Relay & Quick Reply Tests")
struct NotificationTests {

    @Test("Roundtrip serialization of phone_notification with reply support")
    func testPhoneNotificationSerialization() throws {
        let msg = ContinuityMessage(
            type: "phone_notification",
            id: "notif-uuid-49102",
            app: "Telegram",
            title: "Alex",
            text: "Are you free for lunch?",
            canReply: true,
            packageName: "org.telegram.messenger"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(msg)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "phone_notification")
        #expect(decoded.id == "notif-uuid-49102")
        #expect(decoded.app == "Telegram")
        #expect(decoded.title == "Alex")
        #expect(decoded.text == "Are you free for lunch?")
        #expect(decoded.canReply == true)
        #expect(decoded.packageName == "org.telegram.messenger")
    }

    @Test("Roundtrip serialization of notification_reply message")
    func testNotificationReplySerialization() throws {
        let reply = ContinuityMessage(
            type: "notification_reply",
            id: "notif-uuid-49102",
            replyText: "Yes, 12:30 at the cafe!",
            packageName: "org.telegram.messenger"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(reply)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "notification_reply")
        #expect(decoded.id == "notif-uuid-49102")
        #expect(decoded.replyText == "Yes, 12:30 at the cafe!")
        #expect(decoded.packageName == "org.telegram.messenger")
    }

    @Test("Headless notification service safely displays phone notifications")
    func testHeadlessPhoneNotificationSafety() {
        let service = NotificationService.shared

        // In test context, isAvailable is false (no bundle ID). Must execute safely without throwing.
        service.showPhoneNotification(
            id: "test-id-1",
            packageName: "com.whatsapp",
            appName: "WhatsApp",
            title: "Alice",
            body: "Running test message",
            canReply: true,
            sound: false
        )

        // Multiple rapid phone notifications execute cleanly
        for i in 1...10 {
            service.showPhoneNotification(
                id: "bulk-\(i)",
                packageName: "com.test.app",
                appName: "App \(i)",
                title: "Title \(i)",
                body: "Body \(i)",
                canReply: (i % 2 == 0),
                sound: false
            )
        }
    }

    @Test("dispatchReply routes reply to callback")
    func testDispatchReplyRouting() {
        let service = NotificationService.shared
        var receivedId = ""
        var receivedPkg = ""
        var receivedText = ""

        service.onReplyDispatched = { id, pkg, text in
            receivedId = id
            receivedPkg = pkg
            receivedText = text
        }

        service.dispatchReply(id: "msg-12345", packageName: "org.thoughtcrime.securesms", text: "Got your message!")

        #expect(receivedId == "msg-12345")
        #expect(receivedPkg == "org.thoughtcrime.securesms")
        #expect(receivedText == "Got your message!")
    }

    @Test("Notification with empty or nil title/text handles gracefully")
    func testEmptyNotificationFields() throws {
        let emptyJson = """
        {"type": "phone_notification", "id": "empty-1", "packageName": "com.empty"}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: emptyJson)
        #expect(decoded.type == "phone_notification")
        #expect(decoded.id == "empty-1")
        #expect(decoded.title == nil)
        #expect(decoded.text == nil)
        #expect(decoded.canReply == nil)
    }

    @Test("Serialize notification_open message")
    func testNotificationOpenSerialization() throws {
        let msg = ContinuityMessage(type: "notification_open", id: "notif-101", packageName: "org.telegram.messenger")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "notification_open")
        #expect(decoded.id == "notif-101")
        #expect(decoded.packageName == "org.telegram.messenger")
    }

    @Test("onNotificationClicked callback dispatches properly")
    func testNotificationClickCallback() {
        var clickedId = ""
        var clickedPkg = ""
        NotificationService.shared.onNotificationClicked = { id, pkg in
            clickedId = id
            clickedPkg = pkg
        }
        NotificationService.shared.onNotificationClicked?("test-id-99", "com.google.android.youtube")
        #expect(clickedId == "test-id-99")
        #expect(clickedPkg == "com.google.android.youtube")
    }

    @Test("Notification default click triggers notification_open dispatch")
    func testNotificationDefaultClickDispatch() {
        var openedId = ""
        var openedPkg = ""

        NotificationService.shared.onNotificationOpened = { id, pkg in
            openedId = id
            openedPkg = pkg
        }

        NotificationService.shared.dispatchNotificationOpen(id: "test-notif-1", packageName: "com.whatsapp")

        #expect(openedId == "test-notif-1")
        #expect(openedPkg == "com.whatsapp")
    }
}
