import AppKit
import SwiftUI
import GalaxyContinuityKit

public struct CameraPreviewView: View {
    @ObservedObject var state = DeviceState.shared
    @State private var selectedLens: String = "back"
    @State private var zoomLevel: Double = 1.0
    @State private var torchOn: Bool = false

    public init() {}

    public var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Color.black

                if let image = state.lastCameraFrame {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text(state.isCameraActive ? "Streaming camera..." : "Continuity Camera Inactive")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
            .frame(width: 640, height: 480)
            .cornerRadius(12)

            // Camera Controls Bar
            HStack(spacing: 16) {
                // Lens picker
                Picker("Lens", selection: $selectedLens) {
                    Text("Back").tag("back")
                    Text("Front").tag("front")
                    Text("Ultra-Wide").tag("ultra_wide")
                    Text("Telephoto").tag("telephoto")
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
                .onChange(of: selectedLens) { _, newLens in
                    ContinuityCameraService.shared.switchLens(to: newLens)
                }

                // Zoom Slider
                HStack(spacing: 6) {
                    Text("Zoom: \(String(format: "%.1fx", zoomLevel))")
                        .font(.system(size: 11))
                    Slider(value: $zoomLevel, in: 1.0...5.0, step: 0.1) { _ in
                        ContinuityCameraService.shared.setZoom(zoomLevel)
                    }
                    .frame(width: 120)
                }

                // Torch Toggle
                Button(action: {
                    torchOn.toggle()
                    ContinuityCameraService.shared.setTorch(torchOn)
                }) {
                    Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .foregroundColor(torchOn ? .yellow : .secondary)
                }
                .buttonStyle(.bordered)
                .help("Toggle Torch")

                Spacer()

                Button(action: {
                    if state.isCameraActive {
                        ContinuityCameraService.shared.stopCamera()
                    } else {
                        ContinuityCameraService.shared.startCamera(lens: selectedLens)
                    }
                }) {
                    Label(state.isCameraActive ? "Stop" : "Start", systemImage: state.isCameraActive ? "stop.fill" : "play.fill")
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

public final class CameraPreviewWindowController: NSWindowController {
    public static let shared = CameraPreviewWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 664, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Galaxy Continuity Camera"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: CameraPreviewView())
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
