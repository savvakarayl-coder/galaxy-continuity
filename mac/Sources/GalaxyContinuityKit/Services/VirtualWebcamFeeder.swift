import CoreMedia
import CoreVideo
import Foundation

public final class VirtualWebcamFeeder: @unchecked Sendable {
    public static let shared = VirtualWebcamFeeder()

    private let lock = NSLock()
    private var currentJpegData: Data?

    public var isFeederActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isFeederActive
    }
    private var _isFeederActive: Bool = false

    private init() {}

    public func feedJpeg(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        self.currentJpegData = data
        self._isFeederActive = true
    }

    public func getLatestJpeg() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return currentJpegData
    }

    public func stopFeeder() {
        lock.lock()
        defer { lock.unlock() }
        currentJpegData = nil
        _isFeederActive = false
    }
}
