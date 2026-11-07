import AppKit
import SwiftUI
import GalaxyContinuityKit

public struct ScreenMirroringView: View {
    @ObservedObject var state = DeviceState.shared
    @State private var isDragging: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geo in
                ZStack {
                    Color.black

                    if let image = state.lastScreenFrame {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text(state.isScreenMirroringActive ? "Waiting for video stream..." : "Screen Mirroring Inactive")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { val in
                            guard geo.size.width > 0 && geo.size.height > 0 else { return }
                            let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                            let normY = max(0.0, min(1.0, val.location.y / geo.size.height))

                            if !isDragging {
                                isDragging = true
                                let startX = max(0.0, min(1.0, val.startLocation.x / geo.size.width))
                                let startY = max(0.0, min(1.0, val.startLocation.y / geo.size.height))
                                ScreenMirroringService.shared.sendInputEvent(action: "down", x: startX, y: startY, button: 0)
                            } else {
                                ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
                            }
                        }
                        .onEnded { val in
                            isDragging = false
                            guard geo.size.width > 0 && geo.size.height > 0 else { return }
                            let normX = max(0.0, min(1.0, val.location.x / geo.size.width))
                            let normY = max(0.0, min(1.0, val.location.y / geo.size.height))
                            ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
                        }
                )
            }
            .frame(width: 360, height: 720)
            .cornerRadius(16)

            // Hardware Navigation Buttons Bar
            HStack(spacing: 24) {
                Button(action: {
                    ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)
                }) {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .help("Recent Apps")

                Button(action: {
                    ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
                }) {
                    Image(systemName: "circle")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .help("Home")

                Button(action: {
                    ScreenMirroringService.shared.sendKeyInput(key: "BACK", keyCode: 4)
                }) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 14))
                }
                .buttonStyle(.bordered)
                .help("Back")

                Spacer()

                Button(action: {
                    if state.isScreenMirroringActive {
                        ScreenMirroringService.shared.stopMirroring()
                    } else {
                        ScreenMirroringService.shared.startMirroring()
                    }
                }) {
                    Label(state.isScreenMirroringActive ? "Stop" : "Start", systemImage: state.isScreenMirroringActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .padding(12)
        .background(Color(NSColor.windowBackgroundColor))
    }
}

public final class ScreenMirroringWindowController: NSWindowController {
    public static let shared = ScreenMirroringWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 384, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Galaxy Screen Mirror"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ScreenMirroringView())
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
