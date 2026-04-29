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

    // Security-scoped URL for the custom download directory chosen via Files picker.
    // nonisolated(unsafe) because downloadDirectoryURL is called from nonisolated delegate code.
    // Written only in init() and setDownloadDirectory() — both on MainActor before any concurrent use.
    nonisolated(unsafe) private var _scopedDirectoryURL: URL?

    // Dedicated URLSession for HLS segments — separate from mp4Session and URLSession.shared
    private let hlsSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.networkServiceType = .responsiveData
        return URLSession(configuration: cfg)
    }()

    // MARK: - Queries

    func isDownloaded(key: String) -> Bool { localURL(for: key) != nil }
    func isDownloading(key: String) -> Bool { inProgress.contains(key) }

    func localURL(for key: String) -> URL? {
        guard let e = entries[key], !e.localPath.isEmpty else { return nil }
        // resolvingSymlinksInPath converts /var/mobile/... → /private/var/mobile/... so that
        // checkResourceIsReachable (and file I/O) works correctly across app restarts.
        // URL.path does NOT resolve symlinks — storing /var/ paths and reading them back
        // without this call causes false-negative reachability checks on iOS.
        let url = URL(fileURLWithPath: e.localPath).resolvingSymlinksInPath()
        let reachable = (try? url.checkResourceIsReachable()) == true
        let fileExists = FileManager.default.fileExists(atPath: e.localPath)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int64 ?? -1
        print("[MC-DL-DIAG] localURL key=\(key.suffix(40))")
        print("[MC-DL-DIAG]   storedPath=\(e.localPath)")
        print("[MC-DL-DIAG]   resolvedPath=\(url.path)")
        print("[MC-DL-DIAG]   fileExists(storedPath)=\(fileExists) reachable(resolvedPath)=\(reachable) size=\(fileSize)")
        DownloadManager.logResourceValues(url: url, prefix: "  localURL")
        return reachable ? url : nil
    }

    /// Logs URLResourceValues for H2.5 (iCloud offload), data-protection, readability.
    static func logResourceValues(url: URL, prefix: String) {
        let keys: Set<URLResourceKey> = [
            .fileSizeKey, .isReadableKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ]
        let vals = try? url.resourceValues(forKeys: keys)
        let ubiq    = vals?.isUbiquitousItem ?? false
        let dlStatus = vals?.ubiquitousItemDownloadingStatus?.rawValue ?? "n/a"
        let readable = vals?.isReadable ?? false
        let size     = vals?.fileSize ?? -1
        print("[MC-DL-DIAG]\(prefix) resourceValues: size=\(size) readable=\(readable) ubiquitous=\(ubiq) iCloudStatus=\(dlStatus)")
        let prot = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.protectionKey] as? FileProtectionType
        print("[MC-DL-DIAG]\(prefix) protectionKey=\(prot?.rawValue ?? "nil")")
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
            let (manifestData, _) = try await hlsSession.data(from: manifestURL)
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
            let (mediaData, _) = try await hlsSession.data(from: playlistURL)
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
            let dir = DownloadManager.shared.downloadDirectoryURL
            let safe = title
                .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
                .joined(separator: "_")
            let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
            let filename = "\(safe)_\(dateFmt.string(from: Date())).ts"
            let dest = dir.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            FileManager.default.createFile(atPath: dest.path, contents: nil)
            let handle = try FileHandle(forWritingTo: dest)

            // 6. Download segments in parallel batches (8 concurrent), write in order
            let batchSize = 8
            let session = hlsSession
            var totalBytes: Int64 = 0
            var segIndex = 0

            while segIndex < segmentURLs.count {
                if Task.isCancelled { break }
                let batchEnd = min(segIndex + batchSize, segmentURLs.count)
                let batchURLs = Array(segmentURLs[segIndex..<batchEnd])

                let batchResults: [(Int, Data)] = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                    for (i, url) in batchURLs.enumerated() {
                        group.addTask {
                            let (data, _) = try await session.data(from: url)
                            return (i, data)
                        }
                    }
                    var results = [(Int, Data)]()
                    results.reserveCapacity(batchURLs.count)
                    for try await item in group { results.append(item) }
                    return results
                }

                for (_, data) in batchResults.sorted(by: { $0.0 < $1.0 }) {
                    try handle.write(contentsOf: data)
                    totalBytes += Int64(data.count)
                }

                segIndex = batchEnd
                let pct = Double(segIndex) / Double(segmentURLs.count)
                await MainActor.run { [weak self] in
                    self?.progress[key] = pct
                    self?.bytesLoaded[key] = totalBytes
                }
                print(">>> DM: seg \(segIndex)/\(segmentURLs.count) (\(Int(pct*100))%) \(String(format: "%.1f", Double(totalBytes)/1_048_576))MB")
            }
            try handle.close()

            let entry = DownloadEntry(key: key, title: title, quality: quality.quality,
                                      localPath: dest.resolvingSymlinksInPath().path,
                                      savedAt: Date(), isHLS: true)
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

    // MARK: - Download directory

    /// Resolved download folder. Falls back to app Documents if bookmark is stale/missing.
    /// nonisolated — only reads UserDefaults + FileManager, both thread-safe.
    nonisolated var downloadDirectoryURL: URL {
        // Return the already-scoped URL while the security scope is active.
        if let scoped = _scopedDirectoryURL { return scoped }
        // Scope not yet started (e.g. called before init completes) — resolve bookmark raw.
        if let data = UserDefaults.standard.data(forKey: "dm_folder_bookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withoutUI,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale),
               !stale {
                return url
            }
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    var downloadDirectoryDisplayPath: String {
        let url = downloadDirectoryURL
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if url.path == docs.path { return "На iPhone / MediaCast" }
        return url.lastPathComponent
    }

    func setDownloadDirectory(_ url: URL) {
        // Release any previously held scope.
        _scopedDirectoryURL?.stopAccessingSecurityScopedResource()
        _scopedDirectoryURL = nil

        // Scope 1: needed to create the bookmark.
        let accessingForBookmark = url.startAccessingSecurityScopedResource()
        if let bookmark = try? url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            UserDefaults.standard.set(bookmark, forKey: "dm_folder_bookmark")
        }
        if accessingForBookmark { url.stopAccessingSecurityScopedResource() }

        // Scope 2: held open for this session so file I/O works immediately.
        if url.startAccessingSecurityScopedResource() {
            _scopedDirectoryURL = url
            print("[MC-DL-DIAG] security scope opened for new directory: \(url.lastPathComponent)")
        }
    }

    func resetDownloadDirectory() {
        _scopedDirectoryURL?.stopAccessingSecurityScopedResource()
        _scopedDirectoryURL = nil
        UserDefaults.standard.removeObject(forKey: "dm_folder_bookmark")
    }

    /// Re-opens the security scope after the app returns to foreground.
    /// iOS revokes scopes when the app is backgrounded — call this from sceneDidBecomeActive / onReceive(.UIApplication.willEnterForegroundNotification).
    func restoreSecurityScope() {
        guard let data = UserDefaults.standard.data(forKey: "dm_folder_bookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: .withoutUI,
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale), !stale else {
            if stale {
                UserDefaults.standard.removeObject(forKey: "dm_folder_bookmark")
                _scopedDirectoryURL = nil
            }
            return
        }
        _scopedDirectoryURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() {
            _scopedDirectoryURL = url
            print("[MC-DL-DIAG] security scope RESTORED: \(url.lastPathComponent)")
        } else {
            _scopedDirectoryURL = nil
            print("[MC-DL-DIAG] security scope restore FAILED: \(url.path)")
        }
    }

    // MARK: - Init / Persistence

    private override init() {
        super.init()

        let mp4cfg = URLSessionConfiguration.default
        mp4cfg.timeoutIntervalForRequest = 60
        mp4cfg.timeoutIntervalForResource = 3600
        mp4Session = URLSession(configuration: mp4cfg, delegate: self, delegateQueue: nil)

        let docsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        print("[MC-DL-DIAG] ===== DownloadManager.init =====")
        print("[MC-DL-DIAG] CONTAINER_UUID=\(docsURL.path)")
        print("[MC-DL-DIAG] CONTAINER_RESOLVED=\(docsURL.resolvingSymlinksInPath().path)")
        let hasBookmark = UserDefaults.standard.data(forKey: "dm_folder_bookmark") != nil
        print("[MC-DL-DIAG] HAS_BOOKMARK=\(hasBookmark)")

        // Open the security scope for the custom download directory, if one was saved.
        // Without this, FileManager cannot access files in iCloud Drive / external folders
        // after an app restart — the scope is never inherited from a previous session.
        if let data = UserDefaults.standard.data(forKey: "dm_folder_bookmark") {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data,
                                  options: .withoutUI,
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale), !stale {
                if url.startAccessingSecurityScopedResource() {
                    _scopedDirectoryURL = url
                    print("[MC-DL-DIAG] security scope OPENED: \(url.path)")
                } else {
                    print("[MC-DL-DIAG] security scope start FAILED (sandbox restriction?): \(url.path)")
                }
            } else {
                print("[MC-DL-DIAG] bookmark stale=\(stale) — clearing")
                if stale { UserDefaults.standard.removeObject(forKey: "dm_folder_bookmark") }
            }
        }

        let rawData = UserDefaults.standard.data(forKey: "dm_entries_v1")
        print("[MC-DL-DIAG] USERDEFAULTS_KEY=dm_entries_v1 dataSize=\(rawData?.count ?? 0) bytes")

        if let data = rawData,
           let d = try? JSONDecoder().decode([String: DownloadEntry].self, from: data) {
            entries = d
            print("[MC-DL-DIAG] PERSISTED count=\(d.count)")
            for (key, entry) in d.sorted(by: { $0.key < $1.key }) {
                let stored   = entry.localPath
                let resolved = URL(fileURLWithPath: stored).resolvingSymlinksInPath().path
                let existsStored    = FileManager.default.fileExists(atPath: stored)
                let existsResolved  = FileManager.default.fileExists(atPath: resolved)
                let readableStored  = FileManager.default.isReadableFile(atPath: stored)
                let readableResolved = FileManager.default.isReadableFile(atPath: resolved)
                let attrs  = try? FileManager.default.attributesOfItem(atPath: resolved)
                let size   = (attrs?[.size] as? Int64) ?? -1
                let pathChanged = stored != resolved
                print("[MC-DL-DIAG] PERSISTED entry ---")
                print("[MC-DL-DIAG]   key=\(key)")
                print("[MC-DL-DIAG]   title=\(entry.title)")
                print("[MC-DL-DIAG]   quality=\(entry.quality) isHLS=\(entry.isHLS)")
                print("[MC-DL-DIAG]   savedAt=\(entry.savedAt)")
                print("[MC-DL-DIAG]   localPath=\(stored)")
                if pathChanged { print("[MC-DL-DIAG]   resolvedPath=\(resolved)  ← SYMLINK DIFFERS") }
                print("[MC-DL-DIAG]   exists(stored)=\(existsStored) exists(resolved)=\(existsResolved)")
                print("[MC-DL-DIAG]   readable(stored)=\(readableStored) readable(resolved)=\(readableResolved)")
                print("[MC-DL-DIAG]   size=\(size) bytes")
                DownloadManager.logResourceValues(url: URL(fileURLWithPath: resolved), prefix: "  init")
            }
        } else if rawData != nil {
            print("[MC-DL-DIAG] PERSISTED decode FAILED — raw JSON may be corrupt")
            if let raw = rawData, let str = String(data: raw, encoding: .utf8) {
                print("[MC-DL-DIAG]   raw (first 300): \(str.prefix(300))")
            }
        } else {
            print("[MC-DL-DIAG] PERSISTED no data in UserDefaults")
        }
        print("[MC-DL-DIAG] ===== init done =====")
        // Don't prune on init — files might be in iCloud/cloud storage and temporarily
        // unavailable locally. localURL(for:) already returns nil for missing files,
        // so callers handle the "file not accessible" case gracefully.
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

        let dir = DownloadManager.shared.downloadDirectoryURL
        let safe = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: "_")
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        let filename = "\(safe)_\(dateFmt.string(from: Date())).mp4"
        let dest = dir.appendingPathComponent(filename)

        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            print(">>> DM: MP4 saved → \(dest.lastPathComponent)")

            let entry = DownloadEntry(key: key, title: title, quality: qualityLabel,
                                      localPath: dest.resolvingSymlinksInPath().path,
                                      savedAt: Date(), isHLS: false)
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

