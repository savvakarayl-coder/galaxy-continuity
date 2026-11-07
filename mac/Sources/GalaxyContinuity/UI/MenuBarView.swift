import AppKit
import SwiftUI
import GalaxyContinuityKit

public struct MenuBarView: View {
    @ObservedObject var state = DeviceState.shared
    @State private var showingPairing: Bool = false

    public var body: some View {
        VStack(spacing: 14) {
            // Header: Device & Status
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(state.isConnected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: state.isConnected ? "iphone.gen3" : "iphone.slash")
                        .font(.system(size: 15))
                        .foregroundColor(state.isConnected ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.connectedDeviceName)
                        .font(.system(size: 13, weight: .bold))
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.isConnected ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text(state.isConnected ? "Connected" : "Waiting for Galaxy...")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Battery Badge
                if state.hasBatteryInfo {
                    HStack(spacing: 4) {
                        Image(systemName: state.isCharging ? "battery.100.bolt" : "battery.75")
                            .foregroundColor(state.isCharging ? .green : .primary)
                        Text("\(state.batteryLevel)%")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(12)
                }
            }
            .padding(.bottom, 2)

            Divider()

            // Universal Clipboard Card
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Universal Clipboard", systemImage: "doc.on.clipboard")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    Spacer()

                    Toggle("", isOn: $state.clipboardAutoSync)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .help("Auto-sync clipboard across Mac and Galaxy")
                }

                if !state.lastSharedClipboard.isEmpty {
                    if state.lastSharedClipboardType.hasPrefix("image/") {
                        HStack {
                            Image(systemName: "photo")
                                .foregroundColor(.accentColor)
                            Text("Image in clipboard (\(state.lastSharedClipboardType))")
                                .font(.system(size: 11))
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(8)
                    } else {
                        Text(state.lastSharedClipboard)
                            .font(.system(size: 11))
                            .lineLimit(3)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(8)
                    }
                } else {
                    Text("Copy text on Mac or Galaxy to sync instantly")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.05))
                        .cornerRadius(8)
                }

                HStack {
                    Button(action: {
                        ClipboardSyncService.shared.pushCurrentMacClipboardToPhone()
                    }) {
                        Label("Push Mac Clipboard", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()

                    if let lastDate = state.clipboardLastUpdated {
                        Text(lastDate, style: .time)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Divider()

            // Quick Drop Card
            QuickDropView()

            Divider()

            // Screen Mirroring & Continuity Camera Card
            VStack(alignment: .leading, spacing: 8) {
                Text("Continuity Features")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack(spacing: 8) {
                    Button(action: {
                        ScreenMirroringWindowController.shared.show()
                        if !state.isScreenMirroringActive {
                            ScreenMirroringService.shared.startMirroring()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.inset.filled.and.cursorarrow")
                            Text("Screen Mirror")
                                .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button(action: {
                        CameraPreviewWindowController.shared.show()
                        if !state.isCameraActive {
                            ContinuityCameraService.shared.startCamera()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "camera")
                            Text("Camera")
                                .font(.system(size: 11))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            Divider()

            // Quick Actions Bar
            HStack(spacing: 8) {
                Button(action: {
                    showingPairing = true
                }) {
                    Label("Pair Phone", systemImage: "qrcode")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if state.isConnected {
                    Button(action: {
                        pingPhone()
                    }) {
                        Label("Find Phone", systemImage: "bell.badge")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button(action: {
                    NSApplication.shared.terminate(nil)
                }) {
                    Image(systemName: "power")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Quit Galaxy Continuity")
            }
        }
        .padding(16)
        .frame(width: 330)
        .sheet(isPresented: $showingPairing) {
            DevicePairingView()
        }
    }

    private func pingPhone() {
        let msg = ContinuityMessage(
            type: "ping_device",
            source: "mac",
            message: "Finding your Galaxy..."
        )
        ServerManager.shared.broadcastMessage(msg)
    }
}
