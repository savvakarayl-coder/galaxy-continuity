import Foundation

public final class BonjourService: NSObject, NetServiceDelegate {
    public static let shared = BonjourService()

    private var netService: NetService?

    private override init() {
        super.init()
    }

    public func startAdvertising(port: Int) {
        stopAdvertising()

        let deviceName = Host.current().localizedName ?? "Mac"
        let service = NetService(domain: "local.", type: "_galaxycontinuity._tcp.", name: "Galaxy Continuity (\(deviceName))", port: Int32(port))
        service.delegate = self

        let txtDict: [String: String] = [
            "name": deviceName,
            "platform": "macOS",
            "version": "1.0.0"
        ]
        service.setTXTRecord(NetService.data(fromTXTRecord: txtDict.mapValues { $0.data(using: .utf8)! }))

        service.publish(options: .listenForConnections)
        self.netService = service
        print("[Bonjour] Publishing service on port \(port)...")
    }

    public func stopAdvertising() {
        netService?.stop()
        netService = nil
    }

    public func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Service successfully published: \(sender.name)")
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("[Bonjour] Failed to publish service: \(errorDict)")
    }
}
