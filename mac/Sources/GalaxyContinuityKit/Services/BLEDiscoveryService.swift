import CoreBluetooth
import Foundation

public final class BLEDiscoveryService: NSObject, CBPeripheralManagerDelegate, CBCentralManagerDelegate {
    public static let shared = BLEDiscoveryService()

    // MARK: - UUID Constants
    public static let SERVICE_UUID = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    public static let CHAR_DEVICE_INFO = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    public static let CHAR_PAIRING_COMMAND = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    public static let CHAR_STATUS = CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214")

    public static let PROTOCOL_TAG = Data([0x47, 0x43]) // "GC"
    public static let ROLE_MAC_HOST: UInt8 = 0x01
    public static let ROLE_GALAXY_CLIENT: UInt8 = 0x02

    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    private var isAdvertising = false
    private var isScanning = false
    private var targetPort: UInt16 = 8765

    public var onPeerDiscovered: ((_ shortId: String, _ role: UInt8, _ port: UInt16) -> Void)?

    private override init() {
        super.init()
    }

    // MARK: - Payload Framing & Parsing

    public static func buildAdvertisementPayload(role: UInt8 = ROLE_MAC_HOST, port: UInt16 = 8765, shortId: Data) -> Data {
        var payload = Data()
        payload.append(PROTOCOL_TAG) // 2 bytes
        payload.append(role)         // 1 byte
        var bePort = port.bigEndian
        payload.append(Data(bytes: &bePort, count: 2)) // 2 bytes
        let truncatedId = shortId.prefix(4)
        payload.append(truncatedId) // 4 bytes (pad if shorter)
        if truncatedId.count < 4 {
            payload.append(Data(repeating: 0, count: 4 - truncatedId.count))
        }
        return payload // 9 bytes total
    }

    public static func parseAdvertisementPayload(data: Data) -> (role: UInt8, port: UInt16, shortId: String)? {
        guard data.count >= 9 else { return nil }
        guard data[0] == PROTOCOL_TAG[0] && data[1] == PROTOCOL_TAG[1] else { return nil }

        let role = data[2]
        let port = data.subdata(in: 3..<5).withUnsafeBytes { $0.load(as: UInt16.self).bigEndian }
        let shortIdBytes = data.subdata(in: 5..<9)
        let shortId = shortIdBytes.map { String(format: "%02x", $0) }.joined()

        return (role: role, port: port, shortId: shortId)
    }

    // MARK: - Lifecycle

    public func start(port: UInt16 = 8765) {
        self.targetPort = port
        // Initialize managers safely on background queue to avoid main-thread hangs
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
        if centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    public func stop() {
        if isAdvertising {
            peripheralManager?.stopAdvertising()
            isAdvertising = false
        }
        if isScanning {
            centralManager?.stopScan()
            isScanning = false
        }
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn {
            let shortId = Data(UUID().uuidString.utf8.prefix(4))
            let mfgData = Self.buildAdvertisementPayload(role: Self.ROLE_MAC_HOST, port: targetPort, shortId: shortId)

            let service = CBMutableService(type: Self.SERVICE_UUID, primary: true)
            let charInfo = CBMutableCharacteristic(
                type: Self.CHAR_DEVICE_INFO,
                properties: [.read, .notify],
                value: nil,
                permissions: [.readable]
            )
            let charCmd = CBMutableCharacteristic(
                type: Self.CHAR_PAIRING_COMMAND,
                properties: [.write, .writeWithoutResponse],
                value: nil,
                permissions: [.writeable]
            )
            let charStatus = CBMutableCharacteristic(
                type: Self.CHAR_STATUS,
                properties: [.read, .notify],
                value: nil,
                permissions: [.readable]
            )
            service.characteristics = [charInfo, charCmd, charStatus]
            peripheral.add(service)

            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.SERVICE_UUID],
                CBAdvertisementDataLocalNameKey: "Galaxy Continuity (Mac)",
                CBAdvertisementDataManufacturerDataKey: mfgData
            ])
            isAdvertising = true
            print("[BLEDiscovery] Advertising BLE Service \(Self.SERVICE_UUID)...")
        }
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            central.scanForPeripherals(withServices: [Self.SERVICE_UUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            isScanning = true
            print("[BLEDiscovery] Scanning for Galaxy BLE beacons...")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
           let parsed = Self.parseAdvertisementPayload(data: mfgData) {
            print("[BLEDiscovery] Discovered Galaxy peer via BLE: shortId=\(parsed.shortId) role=\(parsed.role) port=\(parsed.port)")
            onPeerDiscovered?(parsed.shortId, parsed.role, parsed.port)
        }
    }
}
