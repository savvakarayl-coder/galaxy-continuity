#if canImport(XCTest)
import XCTest
#endif
#if canImport(Testing)
import Testing
#endif
import Foundation
@testable import GalaxyContinuityKit

#if canImport(XCTest)
final class ContinuityCameraXCTests: XCTestCase {

    func testCameraStartSerialization() throws {
        let msg = ContinuityMessage(
            type: "camera_start",
            fps: 30,
            lens: "back",
            quality: "1080p"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "camera_start")
        XCTAssertEqual(decoded.lens, "back")
        XCTAssertEqual(decoded.quality, "1080p")
        XCTAssertEqual(decoded.fps, 30)
    }

    func testCameraStartAliasResolution() throws {
        let json = """
        {"type":"camera_start","facing":"front","resolution":"720p","fps":30}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.type, "camera_start")
        XCTAssertEqual(decoded.facing, "front")
        XCTAssertEqual(decoded.resolution, "720p")
        XCTAssertEqual(decoded.effectiveLens, "front")
        XCTAssertEqual(decoded.effectiveQuality, "720p")
    }

    func testCameraStopSerialization() throws {
        let msg = ContinuityMessage(type: "camera_stop")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "camera_stop")
    }

    func testCameraSwitchLensSerialization() throws {
        let json = """
        {"type":"camera_switch_lens","facing":"front"}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.type, "camera_switch_lens")
        XCTAssertEqual(decoded.effectiveLens, "front")
    }

    func testCameraControlSerialization() throws {
        let msg = ContinuityMessage(
            type: "camera_control",
            action: "set_zoom",
            zoom: 2.0,
            torch: true
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        XCTAssertEqual(decoded.type, "camera_control")
        XCTAssertEqual(decoded.action, "set_zoom")
        XCTAssertEqual(decoded.zoom, 2.0)
        XCTAssertEqual(decoded.torch, true)
    }

    func testCameraStreamPacketFraming() throws {
        // Mock JPEG starting with 0xFF 0xD8
        let mockJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x02, payload: mockJpeg)
        XCTAssertEqual(packet.count, 5 + mockJpeg.count)
        XCTAssertEqual(packet[0], 0x02)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        XCTAssertEqual(parsed.streamType, 0x02)
        XCTAssertEqual(parsed.length, mockJpeg.count)
        XCTAssertEqual(parsed.payload, mockJpeg)
    }

    func testVirtualWebcamFeederIngestion() {
        let feeder = VirtualWebcamFeeder.shared
        let sampleJpeg = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x01, 0x02])
        feeder.feedJpeg(sampleJpeg)
        XCTAssertTrue(feeder.isFeederActive)
        XCTAssertEqual(feeder.getLatestJpeg(), sampleJpeg)

        feeder.stopFeeder()
        XCTAssertFalse(feeder.isFeederActive)
        XCTAssertNil(feeder.getLatestJpeg())
    }
}
#endif

#if canImport(Testing)
@Suite("Continuity Camera Parity Tests")
struct ContinuityCameraTests {

    @Test("Serialize camera_start control message")
    func testCameraStartSerialization() throws {
        let msg = ContinuityMessage(
            type: "camera_start",
            fps: 30,
            lens: "back",
            quality: "1080p"
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "camera_start")
        #expect(decoded.lens == "back")
        #expect(decoded.quality == "1080p")
        #expect(decoded.fps == 30)
    }

    @Test("Resolve facing and resolution aliases to effectiveLens and effectiveQuality")
    func testCameraStartAliasResolution() throws {
        let json = """
        {"type":"camera_start","facing":"front","resolution":"720p","fps":30}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        #expect(decoded.type == "camera_start")
        #expect(decoded.facing == "front")
        #expect(decoded.resolution == "720p")
        #expect(decoded.effectiveLens == "front")
        #expect(decoded.effectiveQuality == "720p")
    }

    @Test("Serialize camera_stop control message")
    func testCameraStopSerialization() throws {
        let msg = ContinuityMessage(type: "camera_stop")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "camera_stop")
    }

    @Test("Serialize camera_switch_lens control message with facing alias")
    func testCameraSwitchLensSerialization() throws {
        let json = """
        {"type":"camera_switch_lens","facing":"front"}
        """
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: Data(json.utf8))
        #expect(decoded.type == "camera_switch_lens")
        #expect(decoded.effectiveLens == "front")
    }

    @Test("Serialize camera_control parameters (zoom, torch)")
    func testCameraControlSerialization() throws {
        let msg = ContinuityMessage(
            type: "camera_control",
            action: "set_zoom",
            zoom: 2.0,
            torch: true
        )
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ContinuityMessage.self, from: data)
        #expect(decoded.type == "camera_control")
        #expect(decoded.action == "set_zoom")
        #expect(decoded.zoom == 2.0)
        #expect(decoded.torch == true)
    }

    @Test("Binary stream packet framing roundtrip for camera (type 0x02)")
    func testCameraStreamPacketFraming() throws {
        let mockJpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])
        let packet = ScreenMirroringService.makeStreamPacket(streamType: 0x02, payload: mockJpeg)
        #expect(packet.count == 5 + mockJpeg.count)
        #expect(packet[0] == 0x02)

        let parsed = try ScreenMirroringService.parseStreamPacket(packet)
        #expect(parsed.streamType == 0x02)
        #expect(parsed.length == mockJpeg.count)
        #expect(parsed.payload == mockJpeg)
    }

    @Test("VirtualWebcamFeeder stores and returns latest JPEG buffer")
    func testVirtualWebcamFeederIngestion() {
        let feeder = VirtualWebcamFeeder.shared
        let sampleJpeg = Data([0xFF, 0xD8, 0xFF, 0xDB, 0x01, 0x02])
        feeder.feedJpeg(sampleJpeg)
        #expect(feeder.isFeederActive == true)
        #expect(feeder.getLatestJpeg() == sampleJpeg)

        feeder.stopFeeder()
        #expect(feeder.isFeederActive == false)
        #expect(feeder.getLatestJpeg() == nil)
    }
}
#endif
