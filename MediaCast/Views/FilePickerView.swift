import SwiftUI
import UniformTypeIdentifiers

struct FilePickerView: View {
    @Binding var selectedVideo: URL?
    @ObservedObject var httpServer: HTTPServer
    @ObservedObject var dlna: DLNAController
    @Binding var selectedDevice: UPnPDevice?
    @Binding var castingTitle: String
    @ObservedObject var ssdp: SSDPDiscovery

    @State private var showPicker = false
    @State private var isCasting = false
    @State private var castError: String?

    private let videoTypes: [UTType] = [
        .movie, .video, .mpeg4Movie, .avi,
        UTType("public.mkv") ?? .movie
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                VStack(spacing: 20) {
                    selectedFileCard
                    Spacer()
                    pickButton
                }
                .padding()
            }
            .navigationTitle("Файлы")
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showPicker) {
                DocumentPickerView(contentTypes: videoTypes) { url in
                    selectedVideo = url
                    castError = nil
                }
            }
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var selectedFileCard: some View {
        if let video = selectedVideo {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Theme.accentBg)
                            .frame(width: 44, height: 44)
                        Image(systemName: "play.rectangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.accent)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Выбранный файл")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.4)
                            .textCase(.uppercase)
                            .foregroundColor(Theme.textMuted)
                        Text(video.lastPathComponent)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(Theme.textPrimary)
                            .lineLimit(2)
                    }
                }

                if let size = fileSize(for: video) {
                    Text(size)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textSecondary)
                }

                Divider().background(Theme.borderSubtle)

                // Cast to TV button
                if selectedDevice != nil {
                    Button {
                        Task { await castToTV(video: video) }
                    } label: {
                        HStack(spacing: 9) {
                            if isCasting {
                                ProgressView().tint(.white).scaleEffect(0.85)
                            } else {
                                Image(systemName: "tv.fill")
                                    .font(.system(size: 15))
                            }
                            Text(isCasting ? "Подключение…" : "Транслировать на TV")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(isCasting ? Theme.accentDim : Theme.castActive)
                        )
                    }
                    .disabled(isCasting)
                } else {
                    devicePicker
                }

                if let err = castError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
            )
        } else {
            VStack(spacing: 10) {
                Image(systemName: "film.stack")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.textMuted)
                Text("Файл не выбран\nНажмите кнопку ниже, чтобы выбрать видео.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    private var pickButton: some View {
        Button {
            showPicker = true
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15))
                Text(selectedVideo == nil ? "Выбрать файл" : "Сменить файл")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.accent)
            )
        }
    }

    // MARK: - Device picker (shown when no device selected)

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Выберите устройство")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.textMuted)
                Spacer()
                if ssdp.isScanning {
                    ProgressView().scaleEffect(0.7).tint(Theme.accent)
                } else {
                    Button {
                        ssdp.clearAndRediscover()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.accent)
                    }
                }
            }

            if ssdp.devices.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "tv.slash")
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textMuted)
                    Text(ssdp.isScanning ? "Поиск устройств…" : "Устройства не найдены")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                ForEach(ssdp.devices) { device in
                    Button {
                        selectedDevice = device
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "tv.fill")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textMuted)
                            Text(device.friendlyName)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                        }
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.bgTertiary)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.borderMid, lineWidth: 0.5))
        )
    }

    // MARK: - Cast

    private func castToTV(video: URL) async {
        guard let serveURL = httpServer.addVideo(at: video) else {
            castError = "Не удалось запустить локальный сервер (нет Wi-Fi?)."
            return
        }

        isCasting = true
        castError = nil
        do {
            try await dlna.setAVTransportURI(videoURL: serveURL)
            try await dlna.play()
            let title = video.deletingPathExtension().lastPathComponent
            castingTitle = title
            // Record local file to history
            HistoryStore.shared.record(
                key: video.absoluteString,
                title: title,
                poster: nil,
                isLocal: true
            )
        } catch {
            castError = error.localizedDescription
        }
        isCasting = false
    }

    // MARK: - Helpers

    private func fileSize(for url: URL) -> String? {
        guard let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else {
            return nil
        }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

// MARK: - Folder picker

struct FolderPickerView: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: FolderPickerView
        init(parent: FolderPickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            DispatchQueue.main.async {
                self.parent.onPick(url)
                self.parent.dismiss()
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.dismiss()
        }
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

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPickerView

        init(parent: DocumentPickerView) { self.parent = parent }

        func documentPicker(_ controller: UIDocumentPickerViewController,
                            didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

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
