import Combine
import Foundation
import Swifter
import UIKit

@MainActor
final class HTTPServer: ObservableObject {
    @Published private(set) var isRunning = false

    let port: UInt16 = 8080

    private let server = HttpServer()
    // Accessed from Swifter's background threads — protected by fileLock.
    nonisolated(unsafe) private var servedFiles: [String: URL] = [:]
    nonisolated(unsafe) private let fileLock = NSLock()

    init() {
        setupRoutes()
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !server.operating else { return }
        try server.start(port, forceIPv4: false, priority: .default)
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        server.stop()
        fileLock.withLock { servedFiles.removeAll() }
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: - File Registration

    /// Registers a local file and returns its http://localIP:port/video/<filename> base URL.
    func addVideo(at url: URL) -> URL? {
        guard let localIP = NetworkHelper.getLocalIPAddress() else { return nil }
        let filename = url.lastPathComponent
        fileLock.withLock { servedFiles[filename] = url }
        let encoded = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename
        return URL(string: "http://\(localIP):\(port)/video/\(encoded)")
    }

    var serverURL: URL? {
        guard let localIP = NetworkHelper.getLocalIPAddress() else { return nil }
        return URL(string: "http://\(localIP):\(port)")
    }

    // MARK: - Routes

    private func setupRoutes() {
        // Full file or Range-based serving (initial cast, Samsung buffering requests).
        server["/video/:filename"] = { [fileLock, weak self] request in
            guard let self else { return .notFound }

            let raw = request.params[":filename"] ?? ""
            let filename = raw.removingPercentEncoding ?? raw

            let fileURL: URL? = fileLock.withLock { self.servedFiles[filename] }
            guard let fileURL else { return .notFound }

            let path = fileURL.path
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                let fileSize = attrs[.size] as? UInt64,
                fileSize > 0
            else { return .notFound }

            let mime = Self.mimeType(for: path)

            // Range header always takes priority — Samsung uses it for buffering.
            if let rangeHeader = request.headers["range"] {
                return Self.rangeResponse(path: path, fileSize: fileSize,
                                          mime: mime, rangeHeader: rangeHeader)
            } else {
                return Self.fullResponse(path: path, fileSize: fileSize, mime: mime)
            }
        }

    }

    // MARK: - Response helpers

    /// Headers required by Samsung (and DLNA-compliant renderers) to enable the seek bar
    /// and transport controls. DLNA.ORG_OP=01 advertises byte-seek support.
    private static let dlnaHeaders: [String: String] = [
        "transferMode.dlna.org":    "Streaming",
        "contentFeatures.dlna.org": "DLNA.ORG_PN=AVC_MP4_HP_HD_AAC;DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS=01700000000000000000000000000000",
        "Cache-Control":            "no-cache"
    ]

    private static func rangeResponse(
        path: String, fileSize: UInt64, mime: String, rangeHeader: String
    ) -> HttpResponse {
        let (start, end) = parseRange(rangeHeader, fileSize: fileSize)
        let length = end - start + 1

        guard let fh = FileHandle(forReadingAtPath: path) else { return .internalServerError }
        fh.seek(toFileOffset: start)
        let data = fh.readData(ofLength: Int(length))
        fh.closeFile()

        var headers = dlnaHeaders
        headers["Content-Type"]   = mime
        headers["Content-Range"]  = "bytes \(start)-\(end)/\(fileSize)"
        headers["Content-Length"] = "\(length)"
        headers["Accept-Ranges"]  = "bytes"
        return .raw(206, "Partial Content", headers) { writer in
            do { try writer.write(data) }
            catch { print(">>> HTTPServer rangeResponse write error: \(error)") }
        }
    }

    private static func fullResponse(
        path: String, fileSize: UInt64, mime: String
    ) -> HttpResponse {
        guard let fh = FileHandle(forReadingAtPath: path) else { return .internalServerError }
        var headers = dlnaHeaders
        headers["Content-Type"]   = mime
        headers["Content-Length"] = "\(fileSize)"
        headers["Accept-Ranges"]  = "bytes"
        return .raw(200, "OK", headers) { writer in
            defer { fh.closeFile() }
            let chunkSize = 256 * 1024
            while true {
                let chunk = fh.readData(ofLength: chunkSize)
                guard !chunk.isEmpty else { break }
                do { try writer.write(chunk) }
                catch {
                    print(">>> HTTPServer fullResponse write error (client disconnected): \(error)")
                    break
                }
            }
        }
    }

    /// Parses "bytes=start-end" or "bytes=start-" into a clamped (start, end) pair.
    private static func parseRange(_ header: String, fileSize: UInt64) -> (UInt64, UInt64) {
        let value = header.replacingOccurrences(of: "bytes=", with: "")
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let start = parts.first.flatMap { UInt64($0) } ?? 0
        let end: UInt64
        if parts.count > 1, let explicitEnd = UInt64(parts[1]) {
            end = min(explicitEnd, fileSize - 1)
        } else {
            end = fileSize - 1
        }
        return (start, end)
    }

    private static func mimeType(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        case "m4v":  return "video/x-m4v"
        case "mkv":  return "video/x-matroska"
        case "avi":  return "video/x-msvideo"
        case "webm": return "video/webm"
        default:     return "application/octet-stream"
        }
    }
}
