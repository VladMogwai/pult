import Combine
import Foundation

struct DownloadEntry: Codable, Identifiable {
    var id: String { key }
    let key: String
    let title: String
    let quality: String
    var localPath: String   // var — HLS path is filled in after download completes
    let savedAt: Date
    var isHLS: Bool = false
}

// MARK: - DownloadManager

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    @Published private(set) var entries: [String: DownloadEntry] = [:]
    @Published private(set) var inProgress: Set<String> = []
    @Published private(set) var progress: [String: Double] = [:]          // 0–1, or -1 if unknown
    @Published private(set) var bytesLoaded: [String: Int64] = [:]        // always updated
    @Published private(set) var errors: [String: String] = [:]

    // MP4 downloads — delegate-based for real progress
    private var mp4Session: URLSession!
    private var mp4TaskToKey: [URLSessionDownloadTask: String] = [:]

    // Active HLS download tasks (key → Task)
    private var hlsDownloadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - Queries

    func isDownloaded(key: String) -> Bool { localURL(for: key) != nil }
    func isDownloading(key: String) -> Bool { inProgress.contains(key) }

    func localURL(for key: String) -> URL? {
        guard let e = entries[key], !e.localPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: e.localPath)
        return FileManager.default.fileExists(atPath: e.localPath) ? url : nil
    }

    func entry(for key: String) -> DownloadEntry? { entries[key] }

    // MARK: - Start

    func startDownload(
        key: String,
        title: String,
        quality: StreamQuality,
        headers: [String: String]
    ) {
        guard !inProgress.contains(key), !isDownloaded(key: key) else {
            print(">>> DM: already in progress or downloaded [\(key)]")
            return
        }

        errors.removeValue(forKey: key)

        print(">>> DM: startDownload key=[\(key)]")
        print(">>> DM:   directUrl=\(quality.directUrl ?? "nil")")
        print(">>> DM:   streamUrl=\(quality.streamUrl.prefix(120))")

        // Prefer explicit directUrl; fall back to streamUrl if it's an MP4
        let mp4Str = quality.directUrl
            ?? (quality.streamUrl.lowercased().contains(".mp4") ? quality.streamUrl : nil)

        if let mp4Str, let url = URL(string: mp4Str) {
            startMP4Download(key: key, title: title, quality: quality, url: url, headers: headers)
        } else if !quality.streamUrl.isEmpty, let url = URL(string: quality.streamUrl) {
            startHLSDownload(key: key, title: title, quality: quality, url: url)
        } else {
            let msg = "Нет URL для скачивания (directUrl=\(quality.directUrl ?? "nil"), streamUrl=\(quality.streamUrl))"
            print(">>> DM: \(msg)")
            errors[key] = msg
        }
    }

    // MARK: MP4

    private func startMP4Download(
        key: String,
        title: String,
        quality: StreamQuality,
        url: URL,
        headers: [String: String]
    ) {
        print(">>> DM: MP4 start [\(quality.quality)] \(url.absoluteString.prefix(80))")
        inProgress.insert(key)
        progress[key] = 0

        var req = URLRequest(url: url, timeoutInterval: 3600)
        req.timeoutInterval = 3600
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        let task = mp4Session.downloadTask(with: req)
        // Store title/quality alongside the key so we can build the entry in the delegate
        task.taskDescription = "\(key)||||\(title)||||\(quality.quality)"
        mp4TaskToKey[task] = key
        task.resume()
        print(">>> DM: MP4 task \(task.taskIdentifier) started")
    }

    // MARK: HLS (manual segment download — AVAssetDownloadURLSession не работает с этим CDN)

    private func startHLSDownload(
        key: String,
        title: String,
        quality: StreamQuality,
        url: URL
    ) {
        print(">>> DM: HLS start [\(quality.quality)] \(url.absoluteString)")
        inProgress.insert(key)
        progress[key] = 0
        bytesLoaded[key] = 0

        let task = Task { [weak self] in
            guard let self else { return }
            await self.downloadHLSSegments(key: key, title: title, quality: quality, manifestURL: url)
        }
        hlsDownloadTasks[key] = task
    }

    private func downloadHLSSegments(
        key: String,
        title: String,
        quality: StreamQuality,
        manifestURL: URL
    ) async {
        do {
            // 1. Download master manifest
            print(">>> DM: fetching manifest \(manifestURL)")
            let (manifestData, _) = try await URLSession.shared.data(from: manifestURL)
            guard let manifest = String(data: manifestData, encoding: .utf8) else {
                throw NSError(domain: "HLS", code: 0, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать манифест"])
            }

            // 2. If master playlist — find best media playlist URL
            let playlistURL: URL
            if manifest.contains("#EXT-X-STREAM-INF") {
                // Master playlist: pick first (best) stream URL
                let lines = manifest.components(separatedBy: "\n")
                guard let streamLine = lines.first(where: { $0.hasPrefix("http") || ($0.hasPrefix("/") && !$0.hasPrefix("#")) }) else {
                    throw NSError(domain: "HLS", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не найден поток в манифесте"])
                }
                let raw = streamLine.trimmingCharacters(in: .whitespacesAndNewlines)
                playlistURL = raw.hasPrefix("http") ? URL(string: raw)! : URL(string: raw, relativeTo: manifestURL)!.absoluteURL
                print(">>> DM: using stream playlist \(playlistURL)")
            } else {
                playlistURL = manifestURL
            }

            // 3. Download media playlist
            let (mediaData, _) = try await URLSession.shared.data(from: playlistURL)
            guard let mediaManifest = String(data: mediaData, encoding: .utf8) else {
                throw NSError(domain: "HLS", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать медиа-манифест"])
            }

            // 4. Parse segment URLs
            let base = playlistURL.deletingLastPathComponent()
            let segmentURLs: [URL] = mediaManifest
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
                .compactMap { seg in
                    seg.hasPrefix("http") ? URL(string: seg) : URL(string: seg, relativeTo: base)?.absoluteURL
                }

            guard !segmentURLs.isEmpty else {
                throw NSError(domain: "HLS", code: 3, userInfo: [NSLocalizedDescriptionKey: "Нет сегментов в плейлисте"])
            }
            print(">>> DM: \(segmentURLs.count) segments to download")

            // 5. Prepare output file
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let safe = title
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                .joined(separator: "_")
            let filename = "\(abs(key.hashValue))_\(safe.prefix(30))_\(quality.quality).ts"
            let dest = docs.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)

            // 6. Download segments and append
            var totalBytes: Int64 = 0
            for (i, segURL) in segmentURLs.enumerated() {
                if Task.isCancelled { break }
                let (segData, _) = try await URLSession.shared.data(from: segURL)
                try handle.write(contentsOf: segData)
                totalBytes += Int64(segData.count)

                let pct = Double(i + 1) / Double(segmentURLs.count)
                await MainActor.run { [weak self] in
                    self?.progress[key] = pct
                    self?.bytesLoaded[key] = totalBytes
                }
                if i % 10 == 0 {
                    print(">>> DM: seg \(i+1)/\(segmentURLs.count) (\(Int(pct*100))%) \(String(format: "%.1f", Double(totalBytes)/1_048_576))MB")
                }
            }
            try handle.close()

            let entry = DownloadEntry(key: key, title: title, quality: quality.quality,
                                      localPath: dest.path, savedAt: Date(), isHLS: true)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.entries[key] = entry
                self.hlsDownloadTasks.removeValue(forKey: key)
                self.inProgress.remove(key)
                self.progress[key] = 1.0
                self.persist()
                print(">>> DM: HLS done → \(dest.lastPathComponent) (\(String(format: "%.1f", Double(totalBytes)/1_048_576))MB)")
            }
        } catch {
            print(">>> DM: HLS error: \(error.localizedDescription)")
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.errors[key] = error.localizedDescription
                self.hlsDownloadTasks.removeValue(forKey: key)
                self.inProgress.remove(key)
                self.progress.removeValue(forKey: key)
            }
        }
    }

    // MARK: - Remove

    func remove(key: String) {
        for (task, k) in mp4TaskToKey where k == key {
            task.cancel(); mp4TaskToKey.removeValue(forKey: task)
        }
        hlsDownloadTasks[key]?.cancel()
        hlsDownloadTasks.removeValue(forKey: key)
        if let e = entries.removeValue(forKey: key), !e.localPath.isEmpty {
            try? FileManager.default.removeItem(atPath: e.localPath)
        }
        inProgress.remove(key)
        progress.removeValue(forKey: key)
        persist()
    }

    // MARK: - Init / Persistence

    private override init() {
        super.init()

        let mp4cfg = URLSessionConfiguration.default
        mp4cfg.timeoutIntervalForRequest = 60
        mp4cfg.timeoutIntervalForResource = 3600
        mp4Session = URLSession(configuration: mp4cfg, delegate: self, delegateQueue: nil)

        if let data = UserDefaults.standard.data(forKey: "dm_entries_v1"),
           let d = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) {
            entries = d
            for (k, e) in entries where !FileManager.default.fileExists(atPath: e.localPath) {
                entries.removeValue(forKey: k)
            }
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "dm_entries_v1")
        }
    }
}

// MARK: - URLSessionDownloadDelegate (MP4)

extension DownloadManager: URLSessionDownloadDelegate {

    /// Called periodically with real byte counts — drives the progress bar
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let written = totalBytesWritten
        let total   = totalBytesExpectedToWrite
        let pct: Double? = total > 0 ? Double(written) / Double(total) : nil
        Task { @MainActor [weak self] in
            guard let self, let key = self.mp4TaskToKey[downloadTask] else { return }
            self.bytesLoaded[key] = written
            if let pct { self.progress[key] = pct }
            let mb = Double(written) / 1_048_576
            if total > 0 {
                let totalMB = Double(total) / 1_048_576
                if Int(mb * 10) % 5 == 0 {
                    print(">>> DM: MP4 progress \(String(format: "%.1f", mb))MB / \(String(format: "%.1f", totalMB))MB (\(Int((pct ?? 0) * 100))%)")
                }
            } else {
                if Int(mb * 2) % 5 == 0 {
                    print(">>> DM: MP4 progress \(String(format: "%.1f", mb))MB (size unknown)")
                }
            }
        }
    }

    /// File is ready — move from temp location to Documents
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let desc = downloadTask.taskDescription else { return }
        let parts = desc.components(separatedBy: "||||")
        guard parts.count == 3 else { return }
        let key = parts[0], title = parts[1], qualityLabel = parts[2]

        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
        let filename = "\(abs(key.hashValue))_\(safe.prefix(30))_\(qualityLabel).mp4"
        let dest = docs.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            print(">>> DM: MP4 saved → \(dest.lastPathComponent)")

            let entry = DownloadEntry(key: key, title: title, quality: qualityLabel,
                                      localPath: dest.path, savedAt: Date(), isHLS: false)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.entries[key] = entry
                self.mp4TaskToKey.removeValue(forKey: downloadTask)
                self.inProgress.remove(key)
                self.progress[key] = 1.0
                self.persist()
            }
        } catch {
            print(">>> DM: MP4 move error: \(error)")
        }
    }

    /// Called when a download task fails with a network error
    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let dlTask = task as? URLSessionDownloadTask, let error else { return }
        print(">>> DM: MP4 error: \(error.localizedDescription)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let key = self.mp4TaskToKey[dlTask] {
                self.errors[key] = error.localizedDescription
                self.inProgress.remove(key)
                self.progress.removeValue(forKey: key)
            }
            self.mp4TaskToKey.removeValue(forKey: dlTask)
        }
    }

}

