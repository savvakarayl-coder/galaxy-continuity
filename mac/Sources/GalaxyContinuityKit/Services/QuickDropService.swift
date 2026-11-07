import AppKit
import Foundation
import UniformTypeIdentifiers

public struct QuickDropTransferProgress: Equatable {
    public let fileId: String
    public let filename: String
    public let bytesTransferred: Int64
    public let totalBytes: Int64
    public let percentage: Double
    public let isOutgoing: Bool
    public let status: String

    public init(
        fileId: String,
        filename: String,
        bytesTransferred: Int64,
        totalBytes: Int64,
        percentage: Double,
        isOutgoing: Bool,
        status: String
    ) {
        self.fileId = fileId
        self.filename = filename
        self.bytesTransferred = bytesTransferred
        self.totalBytes = totalBytes
        self.percentage = percentage
        self.isOutgoing = isOutgoing
        self.status = status
    }
}

public final class QuickDropService {
    public static let shared = QuickDropService()

    private let queue = DispatchQueue(label: "com.galaxycontinuity.quickdrop", qos: .userInitiated)
    private var activeTransfers: [String: QuickDropTransferProgress] = [:]

    private init() {}

    /// Send a local file to connected Galaxy devices
    public func sendFile(at url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[QuickDropService] File does not exist at: \(url.path)")
            return
        }

        queue.async {
            ServerManager.shared.shareFileToGalaxy(fileURL: url)
        }
    }

    /// Update transfer progress from incoming WebSocket `file_progress`
    public func handleProgressUpdate(message: ContinuityMessage) {
        guard let fileId = message.fileId else { return }
        let transferred = message.bytesTransferred ?? 0
        let total = message.totalBytes ?? 0
        let pct = message.percentage ?? (total > 0 ? (Double(transferred) / Double(total) * 100.0) : 0.0)
        let status = message.status ?? "transferring"

        let progress = QuickDropTransferProgress(
            fileId: fileId,
            filename: message.filename ?? "File",
            bytesTransferred: transferred,
            totalBytes: total,
            percentage: pct,
            isOutgoing: false,
            status: status
        )

        queue.async {
            self.activeTransfers[fileId] = progress
        }
    }

    /// Handle transfer completion notification
    public func handleTransferComplete(message: ContinuityMessage) {
        guard let fileId = message.fileId else { return }
        queue.async {
            self.activeTransfers.removeValue(forKey: fileId)
        }
    }

    /// Resolve filename collisions by appending " (1)", " (2)" before the extension
    public static func resolveCollision(in directory: URL, filename: String) -> URL {
        var targetUrl = directory.appendingPathComponent(filename).standardizedFileURL.resolvingSymlinksInPath()
        let ext = targetUrl.pathExtension
        let base = targetUrl.deletingPathExtension().lastPathComponent
        var counter = 1

        while FileManager.default.fileExists(atPath: targetUrl.path) {
            let newName = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
            targetUrl = directory.appendingPathComponent(newName).standardizedFileURL.resolvingSymlinksInPath()
            counter += 1
        }
        return targetUrl
    }
}
