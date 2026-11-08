import AppKit
import SwiftUI
import GalaxyContinuityKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        setupMenuBar()
        setupPopover()
        startServices()
        setupNotificationHandling()
        setupAdbReverse(port: 8765)

        // Bring Screen Mirror window to front
        ScreenMirroringWindowController.shared.show()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            let image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Galaxy Continuity")?.withSymbolConfiguration(config)
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func setupPopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 330, height: 480)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView())
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func startServices() {
        let port = 8765
        ServerManager.shared.start(port: port)
        BonjourService.shared.startAdvertising(port: port)
        ClipboardSyncService.shared.startMonitoring()
        print("[AppDelegate] Galaxy Continuity initialized successfully.")
    }

    private func setupNotificationHandling() {
        NotificationService.shared.onNotificationClicked = { notifId, packageName in
            Task { @MainActor in
                ScreenMirroringWindowController.shared.show()
                if !DeviceState.shared.isScreenMirroringActive {
                    ScreenMirroringService.shared.startMirroring()
                }
                ServerManager.shared.sendNotificationOpen(id: notifId, packageName: packageName)

                // Fast-path: launch application directly over ADB if connected
                if !packageName.isEmpty {
                    let candidates = [
                        "/tmp/platform-tools/adb",
                        "/usr/local/bin/adb",
                        "/opt/homebrew/bin/adb",
                        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
                    ]
                    if let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
                        DispatchQueue.global(qos: .userInitiated).async {
                            let proc = Process()
                            proc.executableURL = URL(fileURLWithPath: adb)
                            proc.arguments = ["shell", "monkey", "-p", packageName, "-c", "android.intent.category.LAUNCHER", "1"]
                            try? proc.run()
                        }
                    }
                }
            }
        }
    }

    private var adbReverseTimer: Timer?

    private func setupAdbReverse(port: Int = 8765) {
        let candidates = [
            "/tmp/platform-tools/adb",
            "/usr/local/bin/adb",
            "/opt/homebrew/bin/adb",
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"
        ]
        guard let adb = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        let performReverse = {
            DispatchQueue.global(qos: .utility).async {
                for p in [port, 8766] {
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: adb)
                    proc.arguments = ["reverse", "tcp:\(p)", "tcp:\(p)"]
                    try? proc.run()
                }
            }
        }

        // Run immediately
        performReverse()

        // Keep active via periodic daemon check every 3 seconds
        adbReverseTimer?.invalidate()
        adbReverseTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { _ in
            performReverse()
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        adbReverseTimer?.invalidate()
        adbReverseTimer = nil
        ClipboardSyncService.shared.stopMonitoring()
        BonjourService.shared.stopAdvertising()
        ServerManager.shared.stop()
    }
}
