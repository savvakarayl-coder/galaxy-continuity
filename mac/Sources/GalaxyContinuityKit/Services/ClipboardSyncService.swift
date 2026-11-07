import AppKit
import Foundation

@MainActor
public final class ClipboardSyncService {
    public static let shared = ClipboardSyncService()

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var lastSeenContent: String = ""
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

    private func checkPasteboard() {
        guard !isUpdatingInternally else { return }

        let currentCount = NSPasteboard.general.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        guard let currentText = NSPasteboard.general.string(forType: .string),
              !currentText.isEmpty,
              currentText != lastSeenContent else {
            return
        }

        lastSeenContent = currentText
        DeviceState.shared.lastSharedClipboard = currentText
        DeviceState.shared.clipboardLastUpdated = Date()

        if DeviceState.shared.clipboardAutoSync && DeviceState.shared.isConnected {
            print("[ClipboardSync] Detected Mac copy: \(currentText.prefix(40))... Sending to Galaxy.")
            let msg = ContinuityMessage(
                type: "clipboard",
                content: currentText,
                contentType: "text/plain",
                source: "mac"
            )
            ServerManager.shared.broadcastMessage(msg)
        }
    }

    public func handleIncomingClipboard(text: String, sender: String = "Samsung Galaxy") {
        guard !text.isEmpty, text != lastSeenContent else { return }

        isUpdatingInternally = true
        lastSeenContent = text

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        lastChangeCount = NSPasteboard.general.changeCount

        DeviceState.shared.lastSharedClipboard = text
        DeviceState.shared.clipboardLastUpdated = Date()

        isUpdatingInternally = false

        print("[ClipboardSync] Synced from \(sender): \(text.prefix(40))...")
        NotificationService.shared.showNotification(
            title: "📋 Clipboard Synced",
            subtitle: "From \(sender)",
            body: text.count > 100 ? String(text.prefix(100)) + "..." : text,
            sound: false
        )
    }

    public func pushCurrentMacClipboardToPhone() {
        if let currentText = NSPasteboard.general.string(forType: .string), !currentText.isEmpty {
            let msg = ContinuityMessage(
                type: "clipboard",
                content: currentText,
                contentType: "text/plain",
                source: "mac"
            )
            ServerManager.shared.broadcastMessage(msg)
            DeviceState.shared.lastSharedClipboard = currentText
            DeviceState.shared.clipboardLastUpdated = Date()
        }
    }
}
