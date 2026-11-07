#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(Testing)
@Suite("Continuity Camera Adversarial Stress Tests", .serialized)
struct ContinuityCameraAdversarialTests {

    // MARK: - 1. Binary Packet Framing Adversarial Tests

    @Test("Camera stream packet framing with 1 MB JPEG payload (stream type 0x02)")
    func testLargeCameraStreamPacket() throws {
        let oneMegabyte = 1024 * 1024
        // Synthetic JPEG starting with 0xFF 0xD8 SOI and ending with 0xFF 0xD9 EOI
        var mockJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        mockJpeg.append(Data(repeating: 0x88, count: oneMegabyte - 12))
        mockJpeg.append(contentsOf: [0xFF, 0xD9])

        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x02, payload: mockJpeg)
        #expect(packet.count == 5 + mockJpeg.count)
        #expect(packet[0] == 0x02)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.length == mockJpeg.count)
        #expect(parsed.payload.count == mockJpeg.count)
        #expect(parsed.payload == mockJpeg)
    }

    @Test("Camera stream packet rejection for truncated headers (0 to 4 bytes)")
    func testTruncatedHeadersRejection() {
        for count in 0..<5 {
            let truncated = Data(repeating: 0x02, count: count)
            #expect(throws: Error.self) {
                try ScreenMirroringService.parseStreamPacket(truncated)
            }
        }
    }

    @Test("Camera stream packet with declared length exceeding actual buffer is bounded safely")
    func testDeclaredLengthExceedingActualBuffer() throws {
        var packet = Data([0x02])
        var declaredLength = UInt32(50000).bigEndian
        withUnsafeBytes(of: &declaredLength) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: [0xFF, 0xD8, 0xFF, 0xE0]) // Only 4 bytes

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.length == 50000)
        #expect(parsed.payload.count == 4)
        #expect(parsed.payload == Data([0xFF, 0xD8, 0xFF, 0xE0]))
    }

    @Test("Camera stream packet with UInt32 max declared length does not overflow or crash")
    func testDeclaredLengthUInt32Max() throws {
        var packet = Data([0x02])
        var declaredLength = UInt32.max.bigEndian
        withUnsafeBytes(of: &declaredLength) { packet.append(contentsOf: $0) }
        packet.append(contentsOf: [0xDE, 0xAD, 0xBE, 0xEF])

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.payload.count == 4)
    }

    @Test("Zero-length camera payload packet parses cleanly")
    func testZeroLengthCameraPayload() throws {
        let emptyPayload = Data()
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x02, payload: emptyPayload)
        #expect(packet.count == 5)
        #expect(packet[0] == 0x02)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.length == 0)
        #expect(parsed.payload.isEmpty)
    }

    @Test("Declared length 0 with trailing bytes returns empty payload")
    func testDeclaredLengthZeroWithTrailingBytes() throws {
        var packet = Data([0x02, 0x00, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0x01, 0x02, 0x03, 0x04])

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.length == 0)
        #expect(parsed.payload.isEmpty)
    }

    // MARK: - 2. VirtualWebcamFeeder & JPEG Frame Ingestion

    @Test("VirtualWebcamFeeder handles rapid consecutive frame updates")
    func testVirtualWebcamFeederRapidUpdates() {
        let feeder = VirtualWebcamFeeder.shared
        for i in 0..<10 {
            let frame = Data([0xFF, 0xD8, UInt8(i), 0xFF, 0xD9])
            feeder.feedJpeg(frame)
            if let latest = feeder.getLatestJpeg() {
                #expect(latest.count == 5)
            }
        }
        feeder.stopFeeder()
        #expect(feeder.isFeederActive == false)
    }

    @Test("VirtualWebcamFeeder thread-safe concurrent access")
    func testVirtualWebcamFeederConcurrency() {
        let feeder = VirtualWebcamFeeder.shared
        DispatchQueue.concurrentPerform(iterations: 20) { i in
            let frame = Data([0xFF, 0xD8, UInt8(i), 0xFF, 0xD9])
            feeder.feedJpeg(frame)
            _ = feeder.getLatestJpeg()
        }
        feeder.stopFeeder()
        #expect(feeder.isFeederActive == false)
    }

    @Test("ContinuityCameraService handleIncomingFrame with corrupted payloads does not crash")
    func testIncomingCorruptedCameraFrames() {
        let corruptedFrames = [
            Data(),                                    // 0 bytes
            Data([0x00]),                              // 1 byte non-JPEG
            Data([0xFF, 0xD8]),                        // Incomplete JPEG header
            Data(repeating: 0x00, count: 1024),         // Zero filled
            Data(repeating: 0xFF, count: 1024),         // 0xFF filled
            Data("NOT_A_JPEG_PAYLOAD".utf8),           // ASCII string
            Data([0xFF, 0xD8, 0x00, 0x11, 0x22, 0x33])  // Corrupted body
        ]

        for frame in corruptedFrames {
            ContinuityCameraService.shared.handleIncomingFrame(frame)
        }
    }

    // MARK: - 3. Camera Controls & Unknown Lenses

    @Test("Camera lens switching with canonical, unknown, and boundary lens names")
    func testCameraLensSwitchingMatrix() {
        let lenses = [
            "back", "front", "ultra_wide", "telephoto",
            "periscope_zoom_5x", "macro_lens", "depth_sensor", "infrared",
            "", "   ", "UNKNOWN_LENS_SENSOR_XYZ"
        ]

        for lens in lenses {
            ContinuityCameraService.shared.switchLens(to: lens)
            let msg = ContinuityMessage(type: "camera_switch_lens", lens: lens, facing: lens)
            ContinuityCameraService.shared.handlePeerSwitchLens(message: msg)

            let ctrl = ContinuityMessage(type: "camera_control", action: "switch_lens", lens: lens, facing: lens)
            ContinuityCameraService.shared.handlePeerCameraControl(message: ctrl)
        }
    }

    @Test("Digital zoom magnification parameters (0.5x, 1.0x, 2.0x, 10.0x, boundaries)")
    func testDigitalZoomMagnifications() {
        let zoomLevels: [Double] = [
            0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0,
            0.0, -1.0, 100.0, 0.001
        ]

        for zoom in zoomLevels {
            ContinuityCameraService.shared.setZoom(zoom)
            let ctrl = ContinuityMessage(type: "camera_control", action: "set_zoom", zoom: zoom)
            ContinuityCameraService.shared.handlePeerCameraControl(message: ctrl)
        }
    }

    @Test("Torch toggling and rapid toggle spam executes safely")
    func testTorchToggles() {
        for _ in 0..<50 {
            ContinuityCameraService.shared.setTorch(true)
            ContinuityCameraService.shared.setTorch(false)
        }

        let ctrlOn = ContinuityMessage(type: "camera_control", action: "toggle_torch", torch: true)
        ContinuityCameraService.shared.handlePeerCameraControl(message: ctrlOn)

        let ctrlOff = ContinuityMessage(type: "camera_control", action: "toggle_torch", torch: false)
        ContinuityCameraService.shared.handlePeerCameraControl(message: ctrlOff)
    }

    // MARK: - 4. Schema Harmonization & Aliases

    @Test("Resolve facing and resolution aliases in camera_start")
    func testSchemaAliasesInCameraStart() throws {
        // Alias facing and resolution
        let jsonAlias = """
        {"type":"camera_start","facing":"ultra_wide","resolution":"4k","fps":60}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonAlias.utf8))
        #expect(decoded.type == "camera_start")
        #expect(decoded.facing == "ultra_wide")
        #expect(decoded.resolution == "4k")
        #expect(decoded.effectiveLens == "ultra_wide")
        #expect(decoded.effectiveQuality == "4k")
        #expect(decoded.fps == 60)

        ContinuityCameraService.shared.handlePeerCameraStart(message: decoded)
    }

    @Test("Canonical lens and quality take precedence over facing and resolution")
    func testCanonicalPrecedenceOverAliases() throws {
        let jsonBoth = """
        {"type":"camera_start","lens":"telephoto","facing":"front","quality":"1080p","resolution":"720p"}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(jsonBoth.utf8))
        #expect(decoded.effectiveLens == "telephoto")
        #expect(decoded.effectiveQuality == "1080p")
    }

    @Test("Schema alias in camera_switch_lens using facing")
    func testCameraSwitchLensWithFacing() throws {
        let json = """
        {"type":"camera_switch_lens","facing":"periscope_zoom_5x"}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        #expect(decoded.effectiveLens == "periscope_zoom_5x")
        ContinuityCameraService.shared.handlePeerSwitchLens(message: decoded)
    }

    @Test("Schema alias in camera_control using facing")
    func testCameraControlWithFacing() throws {
        let json = """
        {"type":"camera_control","action":"switch_lens","facing":"telephoto","zoom":3.0,"torch":false}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        #expect(decoded.effectiveLens == "telephoto")
        #expect(decoded.zoom == 3.0)
        #expect(decoded.torch == false)
        ContinuityCameraService.shared.handlePeerCameraControl(message: decoded)
    }

    // MARK: - 5. Session Lifecycle & Idempotence

    @Test("camera_start with zero, negative, and extreme fps preserves state integrity")
    func testCameraStartZeroAndExtremeFps() {
        ContinuityCameraService.shared.startCamera(lens: "front", quality: "720p", fps: 0)
        ContinuityCameraService.shared.startCamera(lens: "back", quality: "1080p", fps: -30)
        ContinuityCameraService.shared.startCamera(lens: "ultra_wide", quality: "4k", fps: 120)
        ContinuityCameraService.shared.stopCamera()
    }

    @Test("camera_stop is strictly idempotent across consecutive invocations")
    func testCameraStopIdempotence() {
        for _ in 0..<10 {
            ContinuityCameraService.shared.stopCamera()
        }
        let stopMsg = ContinuityMessage(type: "camera_stop")
        for _ in 0..<10 {
            ContinuityCameraService.shared.handlePeerCameraStop(message: stopMsg)
        }
    }

    @Test("Rapid start and stop camera lifecycle cycling executes without deadlock")
    func testRapidStartStopCycling() {
        for _ in 0..<20 {
            ContinuityCameraService.shared.startCamera(lens: "back", quality: "1080p", fps: 30)
            ContinuityCameraService.shared.stopCamera()
        }
    }
}
#endif
