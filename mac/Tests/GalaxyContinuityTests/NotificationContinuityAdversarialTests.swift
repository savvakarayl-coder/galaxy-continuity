#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
import AppKit
@testable import GalaxyContinuityKit

#if canImport(Testing)
@Suite("Notification Continuity Adversarial Tests", .serialized)
struct NotificationContinuityAdversarialTests {

    // MARK: - 1. Notification Click Window & Stream Lifecycle

    @Test("Notification click when mirror window/stream is inactive triggers activation and notification_open")
    func testNotificationClickWhenMirrorInactive() async throws {
        await MainActor.run {
            DeviceState.shared.setScreenMirroringActive(false)
        }

        var mirrorStarted = false
        var sentNotifId = ""
        var sentPackage = ""

        NotificationService.shared.onNotificationClicked = { id, pkg in
            Task { @MainActor in
                if !DeviceState.shared.isScreenMirroringActive {
                    DeviceState.shared.setScreenMirroringActive(true)
                    mirrorStarted = true
                }
                sentNotifId = id
                sentPackage = pkg
            }
        }

        NotificationService.shared.dispatchNotificationOpen(id: "notif-closed-1", packageName: "com.whatsapp")
        try await Task.sleep(nanoseconds: 50_000_000)

        let isActive = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
        #expect(isActive == true)
        #expect(mirrorStarted == true)
        #expect(sentNotifId == "notif-closed-1")
        #expect(sentPackage == "com.whatsapp")
    }

    @Test("Notification click when mirror is already active does NOT duplicate activation")
    func testNotificationClickWhenMirrorAlreadyActive() async throws {
        await MainActor.run {
            DeviceState.shared.setScreenMirroringActive(true)
        }

        var activationCount = 0
        var sentNotifId = ""

        NotificationService.shared.onNotificationClicked = { id, pkg in
            Task { @MainActor in
                if !DeviceState.shared.isScreenMirroringActive {
                    activationCount += 1
                }
                sentNotifId = id
            }
        }

        NotificationService.shared.dispatchNotificationOpen(id: "notif-open-2", packageName: "org.telegram.messenger")
        try await Task.sleep(nanoseconds: 50_000_000)

        let isActive = await MainActor.run { DeviceState.shared.isScreenMirroringActive }
        #expect(isActive == true)
        #expect(activationCount == 0) // Did NOT attempt duplicate activation
        #expect(sentNotifId == "notif-open-2")
    }

    @Test("Notification click mid-stream preserves existing video frame and frame counter")
    func testNotificationClickMidStreamPreservesFrames() async throws {
        await MainActor.run {
            DeviceState.shared.setScreenMirroringActive(true)
            // Mock a frame
            let mockImage = NSImage(size: NSSize(width: 100, height: 200))
            DeviceState.shared.updateScreenFrame(mockImage)
            DeviceState.shared.updateScreenFrame(mockImage)
        }

        let initialFrameCount = await MainActor.run { DeviceState.shared.screenFrameCount }
        #expect(initialFrameCount >= 2)

        var dispatchedId = ""
        NotificationService.shared.onNotificationClicked = { id, pkg in
            dispatchedId = id
        }

        NotificationService.shared.dispatchNotificationOpen(id: "notif-midstream-3", packageName: "com.slack")
        try await Task.sleep(nanoseconds: 50_000_000)

        let postFrameCount = await MainActor.run { DeviceState.shared.screenFrameCount }
        let hasFrame = await MainActor.run { DeviceState.shared.lastScreenFrame != nil }
        #expect(postFrameCount == initialFrameCount)
        #expect(hasFrame == true)
        #expect(dispatchedId == "notif-midstream-3")
    }

    // MARK: - 2. Rapid Burst & Stress Notification Clicks

    @Test("Burst of 100 concurrent notification clicks does not deadlock or crash")
    func testRapidNotificationClickBurst() async throws {
        var clickCount = 0
        let lock = NSLock()

        NotificationService.shared.onNotificationClicked = { id, pkg in
            lock.lock()
            clickCount += 1
            lock.unlock()
        }

        for i in 1...100 {
            NotificationService.shared.dispatchNotificationOpen(id: "burst-\(i)", packageName: "com.example.app\(i)")
        }

        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(clickCount == 100)
    }

    // MARK: - 3. Edge Case Notification Payloads

    @Test("Notification click with empty ID or empty package name handles safely")
    func testEmptyNotificationClickPayloads() {
        var clickedId: String? = nil
        var clickedPkg: String? = nil

        NotificationService.shared.onNotificationClicked = { id, pkg in
            clickedId = id
            clickedPkg = pkg
        }

        NotificationService.shared.dispatchNotificationOpen(id: "", packageName: "")
        #expect(clickedId == "")
        #expect(clickedPkg == "")

        NotificationService.shared.dispatchNotificationOpen(id: "only-id", packageName: "")
        #expect(clickedId == "only-id")
        #expect(clickedPkg == "")

        NotificationService.shared.dispatchNotificationOpen(id: "", packageName: "com.only.pkg")
        #expect(clickedId == "")
        #expect(clickedPkg == "com.only.pkg")
    }

    @Test("Notification click with special characters and shell metacharacters serializes cleanly")
    func testSpecialCharactersNotificationOpen() throws {
        let maliciousPkg = "com.test.app; rm -rf /; echo 'owned' & `reboot`"
        let maliciousId = "id-&&-||-\"quoted\"-\n-line"

        let msg = ContinuityMessage(type: "notification_open", id: maliciousId, packageName: maliciousPkg)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "notification_open")
        #expect(decoded.id == maliciousId)
        #expect(decoded.packageName == maliciousPkg)
    }
}
#endif

#if canImport(XCTest)
final class NotificationContinuityAdversarialXCTests: XCTestCase {
    func testNotificationClickLifecycleXCTest() {
        let exp = expectation(description: "notification click")
        NotificationService.shared.onNotificationClicked = { id, pkg in
            XCTAssertEqual(id, "test-xctest-1")
            XCTAssertEqual(pkg, "com.example.test")
            exp.fulfill()
        }
        NotificationService.shared.dispatchNotificationOpen(id: "test-xctest-1", packageName: "com.example.test")
        waitForExpectations(timeout: 2.0)
    }

    func testNotificationOpenSerializationXCTest() throws {
        let msg = ContinuityMessage(type: "notification_open", id: "id-42", packageName: "com.test.pkg")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "notification_open")
        XCTAssertEqual(decoded.id, "id-42")
        XCTAssertEqual(decoded.packageName, "com.test.pkg")
    }
}
#endif

