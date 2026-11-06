import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct QuickDropView: View {
    @ObservedObject var state = DeviceState.shared
    @State private var isTargeted: Bool = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quick Drop", systemImage: "arrow.up.circle.badge.clock")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Button(action: {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ServerManager.shared.downloadsDirectory.path)
                }) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Open Downloads Folder")
            }

            // Dropzone
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isTargeted ? Color.blue : Color.secondary.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isTargeted ? Color.blue.opacity(0.1) : Color.secondary.opacity(0.04))
                    )

                VStack(spacing: 6) {
                    Image(systemName: isTargeted ? "arrow.down.doc.fill" : "square.and.arrow.up")
                        .font(.system(size: 20))
                        .foregroundColor(isTargeted ? .blue : .secondary)

                    Text(isTargeted ? "Drop to Send to Galaxy" : "Drag & Drop Files Here")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text("Photos, videos, files of any size")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 16)
            }
            .frame(height: 90)
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isTargeted) { providers in
                handleDrop(providers: providers)
                return true
            }

            // Recent transfers
            if !state.transferredFiles.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent Transfers")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)

                    VStack(spacing: 4) {
                        ForEach(state.transferredFiles.prefix(3)) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.isOutgoing ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                                    .foregroundColor(item.isOutgoing ? .blue : .green)
                                    .font(.system(size: 14))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.filename)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(item.formattedSize) • \(item.isOutgoing ? "Sent to Galaxy" : "Received")")
                                        .font(.system(size: 10))
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if let localPath = item.localPath {
                                    Button(action: {
                                        NSWorkspace.shared.activateFileViewerSelecting([localPath])
                                    }) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(Color.secondary.opacity(0.06))
                            .cornerRadius(8)
                        }
                    }
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let fileUrl = url else { return }
                DispatchQueue.main.async {
                    ServerManager.shared.shareFileToGalaxy(fileURL: fileUrl)
                }
            }
        }
    }
}
