import AppKit
import Foundation
import CryptoKit

@MainActor
public final class ClipboardSyncService {
    public static let shared = ClipboardSyncService()

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var lastSeenContent: String = ""
    private var lastSeenHash: String = ""
    private var lastSentHash: String = ""
    private var isUpdatingInternally: Bool = false

    private init() {
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    public func startMonitoring() {
        stopMonitoring()
        self.lastChangeCount = NSPasteboard.general.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkPasteboard()
            }
        }
    }

    public func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    public func sha256Hex(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func convertTiffToPng(_ tiffData: Data?) -> Data? {
        guard let tiffData = tiffData else { return nil }
        guard let bitmapRep = NSBitmapImageRep(data: tiffData) else { return nil }
        return bitmapRep.representation(using: .png, properties: [:])
    }

    private func checkPasteboard() {
        guard !isUpdatingInternally else { return }

        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        // 1. Check for image data (PNG direct or TIFF converted to PNG)
        if let pngData = NSPasteboard.general.data(forType: .png) ?? convertTiffToPng(NSPasteboard.general.data(forType: .tiff)),
           !pngData.isEmpty {
            let hash = sha256Hex(data: pngData)
            guard hash != lastSeenHash && hash != lastSentHash else { return }

            let base64 = pngData.base64EncodedString()
            lastSeenHash = hash
            lastSentHash = hash
            lastSeenContent = base64

            DeviceState.shared.lastSharedClipboard = base64
            DeviceState.shared.lastSharedClipboardType = "image/png"
            DeviceState.shared.clipboardLastUpdated = Date()

            if DeviceState.shared.clipboardAutoSync && DeviceState.shared.isConnected {
                print("[ClipboardSync] Detected Mac image copy (\(pngData.count) bytes). Sending to Galaxy.")
                let msg = ContinuityMessage(
                    type: "clipboard",
                    content: base64,
                    contentType: "image/png",
                    source: "mac",
                    hash: hash,
                    payload: base64
                )
                ServerManager.shared.broadcastMessage(msg)
            }
            return
        }

        // 2. Check for text data
        if let currentText = NSPasteboard.general.string(forType: .string) {
            let textData = Data(currentText.utf8)
            let hash = sha256Hex(data: textData)
            guard hash != lastSeenHash && hash != lastSentHash && currentText != lastSeenContent else { return }

            lastSeenHash = hash
            lastSentHash = hash
            lastSeenContent = currentText

            DeviceState.shared.lastSharedClipboard = currentText
            DeviceState.shared.lastSharedClipboardType = "text/plain"
            DeviceState.shared.clipboardLastUpdated = Date()

            if DeviceState.shared.clipboardAutoSync && DeviceState.shared.isConnected {
                print("[ClipboardSync] Detected Mac copy: \(currentText.prefix(40))... Sending to Galaxy.")
                let msg = ContinuityMessage(
                    type: "clipboard",
                    content: currentText,
                    contentType: "text/plain",
                    source: "mac",
                    hash: hash,
                    payload: currentText
                )
                ServerManager.shared.broadcastMessage(msg)
            }
            return
        }
    }

    public func handleIncomingClipboard(
        content: String,
        contentType: String = "text/plain",
        hash: String? = nil,
        sender: String = "Samsung Galaxy"
    ) {
        let payloadData = Data(content.utf8)
        let payloadHash = hash ?? sha256Hex(data: payloadData)

        // Echo loop suppression: ignore if already seen or sent
        if (!payloadHash.isEmpty && (payloadHash == lastSentHash || payloadHash == lastSeenHash)) ||
           (!content.isEmpty && content == lastSeenContent) {
            print("[ClipboardSync] Dropping echo clipboard with hash \(payloadHash.prefix(8))...")
            return
        }

        isUpdatingInternally = true
        lastSeenHash = payloadHash
        lastSeenContent = content

        DeviceState.shared.lastSharedClipboard = content
        DeviceState.shared.lastSharedClipboardType = contentType
        DeviceState.shared.clipboardLastUpdated = Date()

        if contentType.hasPrefix("image/") {
            if !content.isEmpty, let imageData = Data(base64Encoded: content, options: [.ignoreUnknownCharacters]), !imageData.isEmpty {
                let imgHash = sha256Hex(data: imageData)
                lastSeenHash = imgHash

                NSPasteboard.general.clearContents()
                NSPasteboard.general.setData(imageData, forType: .png)
                if let image = NSImage(data: imageData), let tiff = image.tiffRepresentation {
                    NSPasteboard.general.setData(tiff, forType: .tiff)
                }
                lastChangeCount = NSPasteboard.general.changeCount

                print("[ClipboardSync] Synced image from \(sender) (\(imageData.count) bytes)")
                NotificationService.shared.showNotification(
                    title: "📋 Image Clipboard Synced",
                    subtitle: "From \(sender)",
                    body: "Image copied to Mac clipboard",
                    sound: false
                )
            } else {
                if content.isEmpty {
                    NSPasteboard.general.clearContents()
                    lastChangeCount = NSPasteboard.general.changeCount
                }
                print("[ClipboardSync] Received empty or invalid image payload")
            }
        } else {
            NSPasteboard.general.clearContents()
            if !content.isEmpty {
                NSPasteboard.general.setString(content, forType: .string)
            }
            lastChangeCount = NSPasteboard.general.changeCount

            print("[ClipboardSync] Synced from \(sender): \(content.prefix(40))...")
            NotificationService.shared.showNotification(
                title: "📋 Clipboard Synced",
                subtitle: "From \(sender)",
                body: content.count > 100 ? String(content.prefix(100)) + "..." : content,
                sound: false
            )
        }

        isUpdatingInternally = false
    }

    public func handleIncomingClipboard(text: String, sender: String = "Samsung Galaxy") {
        handleIncomingClipboard(content: text, contentType: "text/plain", hash: nil, sender: sender)
    }

    public func pushCurrentMacClipboardToPhone() {
        if let pngData = NSPasteboard.general.data(forType: .png) ?? convertTiffToPng(NSPasteboard.general.data(forType: .tiff)), !pngData.isEmpty {
            let hash = sha256Hex(data: pngData)
            let base64 = pngData.base64EncodedString()
            lastSentHash = hash
            lastSeenHash = hash
            lastSeenContent = base64

            let msg = ContinuityMessage(
                type: "clipboard",
                content: base64,
                contentType: "image/png",
                source: "mac",
                hash: hash,
                payload: base64
            )
            ServerManager.shared.broadcastMessage(msg)
            DeviceState.shared.lastSharedClipboard = base64
            DeviceState.shared.lastSharedClipboardType = "image/png"
            DeviceState.shared.clipboardLastUpdated = Date()
        } else if let currentText = NSPasteboard.general.string(forType: .string) {
            let hash = sha256Hex(data: Data(currentText.utf8))
            lastSentHash = hash
            lastSeenHash = hash
            lastSeenContent = currentText

            let msg = ContinuityMessage(
                type: "clipboard",
                content: currentText,
                contentType: "text/plain",
                source: "mac",
                hash: hash,
                payload: currentText
            )
            ServerManager.shared.broadcastMessage(msg)
            DeviceState.shared.lastSharedClipboard = currentText
            DeviceState.shared.lastSharedClipboardType = "text/plain"
            DeviceState.shared.clipboardLastUpdated = Date()
        }
    }
}
