import Foundation
import Testing
@testable import GalaxyContinuityKit

@Suite("Multi-Transport Discovery Tests")
struct DiscoveryTests {

    @Test("Bonjour TXT record dictionary parsing matches protocol keys")
    func testBonjourTXTRecordParsing() {
        let txtDict: [String: String] = [
            "name": "MacBook Pro M3",
            "platform": "macOS",
            "version": "1.0.0",
            "port": "8765",
            "id": "e4b31a89-2041-4cfa-8ab2-8df7d9b40091"
        ]

        let rawData = NetService.data(fromTXTRecord: txtDict.mapValues { $0.data(using: .utf8)! })
        let parsed = BonjourService.parseTXTRecord(data: rawData)

        #expect(parsed["name"] == "MacBook Pro M3")
        #expect(parsed["platform"] == "macOS")
        #expect(parsed["version"] == "1.0.0")
        #expect(parsed["port"] == "8765")
        #expect(parsed["id"] == "e4b31a89-2041-4cfa-8ab2-8df7d9b40091")
    }

    @Test("BLE advertisement payload construction matches byte spec")
    func testBLEAdvertisementPayloadConstruction() {
        let shortId = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let payload = BLEDiscoveryService.buildAdvertisementPayload(
            role: BLEDiscoveryService.ROLE_MAC_HOST,
            port: 8765,
            shortId: shortId
        )

        // Exact 9 bytes
        #expect(payload.count == 9)
        // Tag 'G', 'C'
        #expect(payload[0] == 0x47)
        #expect(payload[1] == 0x43)
        // Role Mac Host (0x01)
        #expect(payload[2] == 0x01)
        // Port 8765 in big-endian (0x22, 0x3D)
        #expect(payload[3] == 0x22)
        #expect(payload[4] == 0x3D)
        // Short ID
        #expect(payload[5] == 0xDE)
        #expect(payload[6] == 0xAD)
        #expect(payload[7] == 0xBE)
        #expect(payload[8] == 0xEF)
    }

    @Test("BLE advertisement payload roundtrip parsing")
    func testBLEAdvertisementPayloadRoundtrip() {
        let shortId = Data([0x01, 0x02, 0x03, 0x04])
        let payload = BLEDiscoveryService.buildAdvertisementPayload(
            role: BLEDiscoveryService.ROLE_GALAXY_CLIENT,
            port: 9000,
            shortId: shortId
        )

        let parsed = BLEDiscoveryService.parseAdvertisementPayload(data: payload)
        #expect(parsed != nil)
        #expect(parsed?.role == BLEDiscoveryService.ROLE_GALAXY_CLIENT)
        #expect(parsed?.port == 9000)
        #expect(parsed?.shortId == "01020304")
    }

    @Test("Corrupted or short BLE advertisement payloads are rejected safely")
    func testCorruptedBLEPayloads() {
        // Less than 9 bytes
        for length in 0..<9 {
            let shortData = Data(repeating: 0x47, count: length)
            #expect(BLEDiscoveryService.parseAdvertisementPayload(data: shortData) == nil)
        }

        // Invalid protocol tag
        var badTag = BLEDiscoveryService.buildAdvertisementPayload(shortId: Data([0x1, 0x2, 0x3, 0x4]))
        badTag[0] = 0x58 // 'X' instead of 'G'
        #expect(BLEDiscoveryService.parseAdvertisementPayload(data: badTag) == nil)
    }

    @Test("ShortId padding handles short input buffers safely")
    func testShortIdPadding() {
        let shortId2Bytes = Data([0xAA, 0xBB])
        let payload = BLEDiscoveryService.buildAdvertisementPayload(shortId: shortId2Bytes)
        #expect(payload.count == 9)

        let parsed = BLEDiscoveryService.parseAdvertisementPayload(data: payload)
        #expect(parsed != nil)
        #expect(parsed?.shortId == "aabb0000")
    }
}
