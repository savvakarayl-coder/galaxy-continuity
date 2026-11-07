import Foundation

public final class BonjourService: NSObject, NetServiceDelegate, NetServiceBrowserDelegate {
    public static let shared = BonjourService()

    public static let SERVICE_TYPE = "_galaxycontinuity._tcp."
    public static let DOMAIN = "local."

    public var stableDeviceId: String = {
        let key = "com.galaxycontinuity.device_id"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }()

    private var netService: NetService?
    private var netBrowser: NetServiceBrowser?
    private var resolvingServices: [NetService] = []

    public var onPeerDiscovered: ((_ name: String, _ host: String, _ port: Int, _ txt: [String: String]) -> Void)?

    private override init() {
        super.init()
    }

    public static func parseTXTRecord(data: Data) -> [String: String] {
        let dict = NetService.dictionary(fromTXTRecord: data)
        var result: [String: String] = [:]
        for (k, v) in dict {
            if let str = String(data: v, encoding: .utf8) {
                result[k] = str
            }
        }
        return result
    }

    public func startAdvertising(port: Int) {
        stopAdvertising()

        let deviceName = Host.current().localizedName ?? "Mac"
        let service = NetService(domain: Self.DOMAIN, type: Self.SERVICE_TYPE, name: "Galaxy Continuity (\(deviceName))", port: Int32(port))
        service.delegate = self

        let txtDict: [String: String] = [
            "name": deviceName,
            "platform": "macOS",
            "version": "1.0.0",
            "port": String(port),
            "id": stableDeviceId
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

    public func startBrowsing() {
        stopBrowsing()
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.searchForServices(ofType: Self.SERVICE_TYPE, inDomain: Self.DOMAIN)
        self.netBrowser = browser
        print("[Bonjour] Searching for peers...")
    }

    public func stopBrowsing() {
        netBrowser?.stop()
        netBrowser = nil
        for s in resolvingServices {
            s.stop()
        }
        resolvingServices.removeAll()
    }

    // MARK: - NetServiceDelegate

    public func netServiceDidPublish(_ sender: NetService) {
        print("[Bonjour] Service successfully published: \(sender.name)")
    }

    public func netService(_ sender: NetService, didNotPublish errorDict: [String : NSNumber]) {
        print("[Bonjour] Failed to publish service: \(errorDict)")
    }

    public func netServiceDidResolveAddress(_ sender: NetService) {
        guard let host = sender.hostName else { return }
        let port = sender.port
        let txtData = sender.txtRecordData() ?? Data()
        let txt = Self.parseTXTRecord(data: txtData)
        print("[Bonjour] Resolved peer: \(sender.name) at \(host):\(port)")
        onPeerDiscovered?(sender.name, host, port, txt)
        resolvingServices.removeAll { $0 == sender }
    }

    public func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        print("[Bonjour] Did not resolve peer \(sender.name): \(errorDict)")
        resolvingServices.removeAll { $0 == sender }
    }

    // MARK: - NetServiceBrowserDelegate

    public func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        print("[Bonjour] Discovered peer candidate: \(service.name)")
        service.delegate = self
        resolvingServices.append(service)
        service.resolve(withTimeout: 5.0)
    }

    public func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        print("[Bonjour] Peer left: \(service.name)")
        resolvingServices.removeAll { $0 == service }
    }
}
