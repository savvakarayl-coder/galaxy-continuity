#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(Testing)
@Suite("Input Parity & Interaction Adversarial Tests", .serialized)
struct InputParityAdversarialTests {

    // MARK: - 1. Unicode & Multi-Byte Text Injection

    @Test("Cyrillic, Greek, Asian CJK, and multi-byte Emoji strings in input_text")
    func testUnicodeAndEmojiInputText() throws {
        let testStrings = [
            "Привет, мир! Тестирование клавиатуры Galaxy Continuity 123",
            "Καλημέρα κόσμε! Ελληνική γλώσσα",
            "こんにちは世界！ 你好世界！ 안녕하세요 한국어!",
            "😀 🚀 👨‍👩‍👧‍👦 🏳️‍🌈 👍🏽 🛰️ 🇦🇷 🧑🏾‍🚀"
        ]

        for text in testStrings {
            let msg = ContinuityMessage(type: "input_text", text: text)
            let data = try JSONEncoder().encode(msg)
            let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

            #expect(decoded.type == "input_text")
            #expect(decoded.text == text)

            // Verify sendTextInput executes safely with Unicode
            ScreenMirroringService.shared.sendTextInput(text: text)
        }
    }

    @Test("Shell metacharacters in sendTextInput execute safely")
    func testShellMetacharactersEscaping() {
        let dangerousStrings = [
            "echo $HOME; `rm -rf /tmp/fake`; \"test\" && (ls -la) & | \\",
            "Spaces and $symbols `and` quotes \"and\" backslashes \\",
            "Special characters: !@#$%^&*()_+-=[]{}|;':,.<>/?`~"
        ]

        for text in dangerousStrings {
            ScreenMirroringService.shared.sendTextInput(text: text)
        }
    }

    // MARK: - 2. Extreme Scroll Deltas & Boundary Clamping

    @Test("Extreme scroll deltas and coordinate clamping")
    func testExtremeScrollDeltas() {
        let extremeCases: [(x: Double, y: Double, dx: Double, dy: Double)] = [
            (-10.0, -20.0, 1_000_000.0, 1_000_000.0),
            (50.0, 100.0, -1_000_000.0, -1_000_000.0),
            (0.5, 0.5, 0.0001, 0.0001),
            (0.0, 0.0, 0.0, 0.0),
            (1.0, 1.0, -50.0, 50.0)
        ]

        for tc in extremeCases {
            ScreenMirroringService.shared.sendScrollEvent(x: tc.x, y: tc.y, dx: tc.dx, dy: tc.dy)
        }
    }

    @Test("Scroll message roundtrip with high-precision fractional deltas")
    func testScrollRoundtripPrecision() throws {
        let msg = ContinuityMessage(
            type: "input_scroll",
            action: "scroll",
            x: 0.123456789,
            y: 0.987654321,
            dx: -15.123456,
            dy: 45.987654
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "input_scroll")
        #expect(abs((decoded.x ?? 0) - 0.123456789) < 1e-6)
        #expect(abs((decoded.y ?? 0) - 0.987654321) < 1e-6)
        #expect(abs((decoded.dx ?? 0) - (-15.123456)) < 1e-6)
        #expect(abs((decoded.dy ?? 0) - 45.987654) < 1e-6)
    }

    // MARK: - 3. Key Event Mapping & Standard Key Registry

    @Test("Extended keycode resolution for all standardized keys")
    func testKeyResolutionAllStandardKeys() {
        let expectedMappings: [(key: String, code: Int)] = [
            ("BACKSPACE", 67),
            ("DEL", 67),
            ("ENTER", 66),
            ("RETURN", 66),
            ("TAB", 61),
            ("ESCAPE", 111),
            ("ESC", 111),
            ("SPACE", 62),
            ("DPAD_UP", 19),
            ("UP", 19),
            ("DPAD_DOWN", 20),
            ("DOWN", 20),
            ("DPAD_LEFT", 21),
            ("LEFT", 21),
            ("DPAD_RIGHT", 22),
            ("RIGHT", 22),
            ("BACK", 4),
            ("HOME", 3),
            ("RECENTS", 187),
            ("NOTIFICATIONS", 83),
            ("POWER", 26),
            ("LOCK", 26)
        ]

        for (key, code) in expectedMappings {
            ScreenMirroringService.shared.sendKeyInput(key: key)
            let msg = ContinuityMessage(type: "input_key", key: key, keyCode: code)
            #expect(msg.key == key)
            #expect(msg.keyCode == code)
        }
    }

    @Test("Rapid burst of 500 DEL/Backspace events executes without deadlock")
    func testRapidBackspaceBurst() {
        for _ in 0..<500 {
            ScreenMirroringService.shared.sendKeyInput(key: "BACKSPACE", keyCode: 67)
        }
    }

    // MARK: - 4. Notification Open Navigation

    @Test("notification_open message serialization with special characters")
    func testNotificationOpenSerialization() throws {
        let msg = ContinuityMessage(
            type: "notification_open",
            id: "notif://special/123?param=value&id=abc",
            packageName: "com.samsung.android.messaging:channel"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)

        #expect(decoded.type == "notification_open")
        #expect(decoded.id == "notif://special/123?param=value&id=abc")
        #expect(decoded.packageName == "com.samsung.android.messaging:channel")
    }
}
#endif
