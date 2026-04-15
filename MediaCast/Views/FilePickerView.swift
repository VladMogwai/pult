import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @Binding var selectedVideo: URL?
    @ObservedObject var httpServer: HTTPServer

    @State private var showPicker = false

    // Supported video UTTypes
    private let videoTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .avi,
        UTType("public.mkv") ?? .movie
    ]

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                selectedFileCard
                Spacer()
                pickButton
            }
            .padding()
            .navigationTitle("Files")
            .sheet(isPresented: $showPicker) {
                DocumentPickerView(contentTypes: videoTypes) { url in
                    selectedVideo = url
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var selectedFileCard: some View {
        if let video = selectedVideo {
            VStack(alignment: .leading, spacing: 12) {
                Label("Selected File", systemImage: "film")
                    .font(.headline)

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "play.rectangle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.lastPathComponent)
                            .font(.subheadline)
                            .lineLimit(3)

                        if let size = fileSize(for: video) {
                            Text(size)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()

                if httpServer.isRunning, let serveURL = httpServer.addVideo(at: video) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Serving at:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(serveURL.absoluteString)
                            .font(.caption2)
                            .foregroundStyle(.blue)
                            .lineLimit(2)
                    }
                }
            }
            .padding()
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        } else {
            ContentUnavailableView {
                Label("No File Selected", systemImage: "film.stack")
            } description: {
                Text("Tap the button below to choose a video from your device.")
            }
        }
    }

    private var pickButton: some View {
        Button {
            showPicker = true
        } label: {
            Label(
                selectedVideo == nil ? "Select Video File" : "Change File",
                systemImage: "folder.badge.plus"
            )
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.blue)
            .foregroundStyle(.white)
            .cornerRadius(14)
            .font(.headline)
        }
    }

    // MARK: - Helpers

    private func fileSize(for url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - UIDocumentPickerViewController wrapper

private struct DocumentPickerView: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    // MARK: Coordinator

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(parent: DocumentPickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            // Copy to app's tmp dir so the server can access it even after
            // the security-scoped bookmark expires.
            let accessed = url.startAccessingSecurityScopedResource()
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)

            do {
                if FileManager.default.fileExists(atPath: dest.path) {
                    try FileManager.default.removeItem(at: dest)
                }
                try FileManager.default.copyItem(at: url, to: dest)
                if accessed { url.stopAccessingSecurityScopedResource() }
                DispatchQueue.main.async {
                    self.parent.onPick(dest)
                    self.parent.dismiss()
                }
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                // Fall back to the original URL — works if the bookmark is still valid.
                DispatchQueue.main.async {
                    self.parent.onPick(url)
                    self.parent.dismiss()
                }
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
    }
}
