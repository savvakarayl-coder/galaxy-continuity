import AppKit
import SwiftUI
import GalaxyContinuityKit

public struct ScreenMirroringView: View {
    @ObservedObject var state = DeviceState.shared
    @ObservedObject var windowState = ScreenMirroringWindowState.shared
    @State private var isDragging: Bool = false
    @State private var isHoveringToolbar: Bool = false

    private let chassisPadding: CGFloat = 8
    private let outerRadius: CGFloat = 32
    private let innerRadius: CGFloat = 22

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            let availableWidth = max(100, geo.size.width - chassisPadding * 2)
            let availableHeight = max(200, geo.size.height - chassisPadding * 2)
            let screenWidth = availableWidth
            let screenHeight = availableHeight

            ZStack {
                // Dark titanium smartphone chassis outer frame
                RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(white: 0.18),
                                Color(white: 0.12),
                                Color(white: 0.08)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: outerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color(white: 0.35),
                                        Color(white: 0.20),
                                        Color(white: 0.12)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1.5
                            )
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 16, x: 0, y: 8)

                // Inner Smartphone Screen
                ZStack(alignment: .top) {
                    // Display background
                    Color.black

                    // Video stream or inactive placeholder
                    if let image = state.lastScreenFrame {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: screenWidth, height: screenHeight)
                            .clipped()
                    } else {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.0)
                            Text(state.isScreenMirroringActive ? "Waiting for video stream..." : "Screen Mirroring Inactive")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white.opacity(0.8))
                            if !state.isScreenMirroringActive {
                                Button(action: {
                                    ScreenMirroringService.shared.startMirroring()
                                }) {
                                    Label("Start Mirroring", systemImage: "play.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.blue)
                                .padding(.top, 4)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    // Touch input gesture surface
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { val in
                                    let normX = max(0.0, min(1.0, val.location.x / screenWidth))
                                    let normY = max(0.0, min(1.0, val.location.y / screenHeight))

                                    if !isDragging {
                                        isDragging = true
                                        let startX = max(0.0, min(1.0, val.startLocation.x / screenWidth))
                                        let startY = max(0.0, min(1.0, val.startLocation.y / screenHeight))
                                        ScreenMirroringService.shared.sendInputEvent(action: "down", x: startX, y: startY, button: 0)
                                    } else {
                                        ScreenMirroringService.shared.sendInputEvent(action: "move", x: normX, y: normY, button: 0)
                                    }
                                }
                                .onEnded { val in
                                    isDragging = false
                                    let normX = max(0.0, min(1.0, val.location.x / screenWidth))
                                    let normY = max(0.0, min(1.0, val.location.y / screenHeight))
                                    ScreenMirroringService.shared.sendInputEvent(action: "up", x: normX, y: normY, button: 0)
                                }
                        )

                    // Top camera punch hole cutout (Samsung Infinity-O)
                    Circle()
                        .fill(Color.black)
                        .frame(width: 9, height: 9)
                        .overlay(
                            Circle()
                                .stroke(Color(white: 0.22), lineWidth: 0.75)
                        )
                        .padding(.top, 6)
                        .allowsHitTesting(false)

                    // Bottom home indicator bar
                    VStack {
                        Spacer()
                        Capsule()
                            .fill(Color.white.opacity(0.65))
                            .frame(width: 100, height: 4)
                            .padding(.bottom, 6)
                            .contentShape(Rectangle().size(width: 120, height: 24))
                            .gesture(
                                DragGesture(minimumDistance: 5)
                                    .onEnded { val in
                                        if val.translation.height < -20 {
                                            ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)
                                        } else {
                                            ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
                                        }
                                    }
                            )
                            .onTapGesture {
                                ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
                            }
                    }

                    // Minimal floating hover toolbar at top
                    VStack {
                        floatingToolbar
                            .padding(.top, 12)
                            .opacity(isHoveringToolbar ? 1.0 : 0.0)
                            .animation(.easeInOut(duration: 0.2), value: isHoveringToolbar)
                        Spacer()
                    }
                }
                .frame(width: screenWidth, height: screenHeight)
                .clipShape(RoundedRectangle(cornerRadius: innerRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: innerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
                )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onHover { hovering in
            isHoveringToolbar = hovering
        }
    }

    private var floatingToolbar: some View {
        HStack(spacing: 12) {
            Button(action: {
                ScreenMirroringWindowController.shared.close()
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help("Close Window")

            Divider()
                .frame(height: 12)
                .background(Color.white.opacity(0.2))

            Button(action: {
                ScreenMirroringService.shared.sendKeyInput(key: "RECENTS", keyCode: 187)
            }) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Recent Apps")

            Button(action: {
                ScreenMirroringService.shared.sendKeyInput(key: "HOME", keyCode: 3)
            }) {
                Image(systemName: "circle")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Home")

            Button(action: {
                ScreenMirroringService.shared.sendKeyInput(key: "BACK", keyCode: 4)
            }) {
                Image(systemName: "chevron.backward")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Back")

            Button(action: {
                ScreenMirroringService.shared.sendKeyInput(key: "NOTIFICATIONS", keyCode: 83)
            }) {
                Image(systemName: "bell")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Notifications")

            Button(action: {
                ScreenMirroringService.shared.sendKeyInput(key: "POWER", keyCode: 26)
            }) {
                Image(systemName: "lock")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .help("Lock / Power")

            Divider()
                .frame(height: 12)
                .background(Color.white.opacity(0.2))

            Button(action: {
                if state.isScreenMirroringActive {
                    ScreenMirroringService.shared.stopMirroring()
                } else {
                    ScreenMirroringService.shared.startMirroring()
                }
            }) {
                Image(systemName: state.isScreenMirroringActive ? "stop.fill" : "play.fill")
                    .font(.system(size: 12))
                    .foregroundColor(state.isScreenMirroringActive ? .red : .green)
            }
            .buttonStyle(.plain)
            .help(state.isScreenMirroringActive ? "Stop Mirroring" : "Start Mirroring")

            Divider()
                .frame(height: 12)
                .background(Color.white.opacity(0.2))

            Button(action: {
                ScreenMirroringWindowState.shared.togglePinned()
            }) {
                Image(systemName: windowState.isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .foregroundColor(windowState.isPinned ? .yellow : .white.opacity(0.85))
            }
            .buttonStyle(.plain)
            .help(windowState.isPinned ? "Unpin Window (Allow Move / Normal Level)" : "Pin Window (Lock in Place & Always on Top)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.75))
                .overlay(
                    Capsule()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
                )
        )
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
    }
}

public final class ScreenMirroringWindowState: ObservableObject {
    public static let shared = ScreenMirroringWindowState()
    @Published public var isPinned: Bool = false

    private init() {}

    public func togglePinned() {
        isPinned.toggle()
        ScreenMirroringWindowController.shared.applyPinnedState(isPinned)
    }
}

public final class ScreenMirroringWindowController: NSWindowController {
    public static let shared = ScreenMirroringWindowController()
    private var eventMonitor: Any?
    private var lastScrollTime: Date = Date()
    private var accumulatedDx: Double = 0
    private var accumulatedDy: Double = 0

    public func applyPinnedState(_ pinned: Bool) {
        guard let win = self.window else { return }
        // When pinned: disable dragging window by background and keep floating above all windows
        win.isMovableByWindowBackground = !pinned
        win.level = pinned ? .floating : .normal
    }

    private init() {
        // Compact default window size (260 x 578) with aspect ratio 9:20 (0.45)
        // Perfectly clears the macOS Dock on 800-900pt screens while remaining freely resizable
        let contentRect = NSRect(x: 0, y: 0, width: 260, height: 578)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Galaxy Screen Mirror"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 9, height: 20)
        window.minSize = NSSize(width: 180, height: 400)
        window.maxSize = NSSize(width: 450, height: 1000)

        // Suppress standard titlebar traffic lights for frameless smartphone design
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.contentView = NSHostingView(rootView: ScreenMirroringView())
        super.init(window: window)
        setupEventMonitor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            guard let self = self, let win = self.window, event.window == win else {
                return event
            }

            if event.type == .keyDown {
                if self.handleKeyDown(event) {
                    return nil // Intercepted: consume event to prevent error chime
                }
            } else if event.type == .scrollWheel {
                if self.handleScrollWheel(event) {
                    return nil
                }
            }
            return event
        }
    }

    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // Allow system Command shortcuts (Cmd+W, Cmd+Q) to pass through to macOS
        if event.modifierFlags.contains(.command) {
            if event.charactersIgnoringModifiers == "w" {
                self.window?.performClose(nil)
                return true
            }
            return false
        }

        // Special Key Mappings to Android KeyCodes
        switch event.keyCode {
        case 51: // Mac Delete/Backspace -> Android KEYCODE_DEL (67)
            ScreenMirroringService.shared.sendKeyInput(key: "BACKSPACE", keyCode: 67)
            return true
        case 36, 76: // Mac Return / Enter -> Android KEYCODE_ENTER (66)
            ScreenMirroringService.shared.sendKeyInput(key: "ENTER", keyCode: 66)
            return true
        case 48: // Mac Tab -> Android KEYCODE_TAB (61)
            ScreenMirroringService.shared.sendKeyInput(key: "TAB", keyCode: 61)
            return true
        case 53: // Mac Escape -> Android KEYCODE_ESCAPE (111)
            ScreenMirroringService.shared.sendKeyInput(key: "ESCAPE", keyCode: 111)
            return true
        case 49: // Mac Spacebar -> Android KEYCODE_SPACE (62)
            ScreenMirroringService.shared.sendKeyInput(key: "SPACE", keyCode: 62)
            return true
        case 123: // Mac Left Arrow -> Android KEYCODE_DPAD_LEFT (21)
            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_LEFT", keyCode: 21)
            return true
        case 124: // Mac Right Arrow -> Android KEYCODE_DPAD_RIGHT (22)
            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_RIGHT", keyCode: 22)
            return true
        case 125: // Mac Down Arrow -> Android KEYCODE_DPAD_DOWN (20)
            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_DOWN", keyCode: 20)
            return true
        case 126: // Mac Up Arrow -> Android KEYCODE_DPAD_UP (19)
            ScreenMirroringService.shared.sendKeyInput(key: "DPAD_UP", keyCode: 19)
            return true
        default:
            break
        }

        // Printable text characters typed on Mac keyboard
        if let chars = event.characters, !chars.isEmpty {
            let printable = chars.filter { char in
                guard let scalar = char.unicodeScalars.first else { return false }
                return !CharacterSet.controlCharacters.contains(scalar) && scalar.value >= 32 && scalar.value != 127
            }
            if !printable.isEmpty {
                ScreenMirroringService.shared.sendTextInput(text: printable)
                return true
            }
        }

        return false
    }

    private func handleScrollWheel(_ event: NSEvent) -> Bool {
        guard let win = self.window, let contentView = win.contentView else { return false }
        let mouseLocation = event.locationInWindow
        let bounds = contentView.bounds

        let bezel: CGFloat = 12
        let screenWidth = max(1.0, bounds.width - bezel * 2)
        let screenHeight = max(1.0, bounds.height - bezel * 2)

        let normX = max(0.0, min(1.0, Double((mouseLocation.x - bezel) / screenWidth)))
        let normY = max(0.0, min(1.0, Double((bounds.height - bezel - mouseLocation.y) / screenHeight)))

        var dx = Double(event.scrollingDeltaX)
        var dy = Double(event.scrollingDeltaY)
        if event.hasPreciseScrollingDeltas {
            dx *= 2.0
            dy *= 2.0
        }

        accumulatedDx += dx
        accumulatedDy += dy

        let now = Date()
        let elapsed = now.timeIntervalSince(lastScrollTime)
        // High responsiveness: trigger at 30ms or 8pt delta for buttery smooth swipes
        if elapsed >= 0.03 || abs(accumulatedDx) >= 8 || abs(accumulatedDy) >= 8 {
            ScreenMirroringService.shared.sendScrollEvent(
                x: normX,
                y: normY,
                dx: accumulatedDx,
                dy: accumulatedDy
            )
            accumulatedDx = 0
            accumulatedDy = 0
            lastScrollTime = now
        }
        return true
    }

    public func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public override func close() {
        super.close()
        window?.performClose(nil)
    }
}
