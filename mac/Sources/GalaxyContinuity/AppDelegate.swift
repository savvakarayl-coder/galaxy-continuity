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

    public func applicationWillTerminate(_ notification: Notification) {
        ClipboardSyncService.shared.stopMonitoring()
        BonjourService.shared.stopAdvertising()
        ServerManager.shared.stop()
    }
}
