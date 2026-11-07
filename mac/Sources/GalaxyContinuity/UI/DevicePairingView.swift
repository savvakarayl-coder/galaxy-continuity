import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import GalaxyContinuityKit

public struct DevicePairingView: View {
    @ObservedObject var state = DeviceState.shared
    @Environment(\.dismiss) var dismiss

    var connectionURLString: String {
        "http://\(state.localIPAddress):\(state.serverPort)"
    }

    public var body: some View {
        VStack(spacing: 20) {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundColor(.blue)
                Text("Connect Samsung Galaxy")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if let qrImage = generateQRCode(from: connectionURLString) {
                Image(nsImage: qrImage)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 200, height: 200)
                    .background(Color.white)
                    .cornerRadius(12)
                    .shadow(color: .black.opacity(0.15), radius: 6, x: 0, y: 3)
            }

            VStack(spacing: 6) {
                Text("Scan with Samsung Camera or Browser")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Text(connectionURLString)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(6)
            }

            HStack(spacing: 12) {
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connectionURLString, forType: .string)
                }) {
                    Label("Copy Link", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button(action: {
                    if let url = URL(string: connectionURLString) {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Label("Open in Browser", systemImage: "safari")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    private func generateQRCode(from string: String) -> NSImage? {
        let context = CIContext()
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }

        let data = Data(string.utf8)
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let outputImage = filter.outputImage else { return nil }

        let transform = CGAffineTransform(scaleX: 10, y: 10)
        let scaledImage = outputImage.transformed(by: transform)

        guard let cgImage = context.createCGImage(scaledImage, from: scaledImage.extent) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: 200, height: 200))
    }
}
