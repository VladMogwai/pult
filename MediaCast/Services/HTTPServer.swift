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

    struct ProxyItem {
        let targetURL: URL
        let headers: [String: String]
    }
    nonisolated(unsafe) private var proxyItems: [String: ProxyItem] = [:]
    nonisolated(unsafe) private let proxyLock = NSLock()

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

    // MARK: - Proxy Registration

    /// Registers a CDN URL + required headers and returns a local proxy URL.
    /// TV requests the local URL → phone fetches from CDN with stored headers → streams back.
    func addProxy(targetURL: URL, headers: [String: String]) -> URL? {
        guard let localIP = NetworkHelper.getLocalIPAddress() else { return nil }
        let proxyId = UUID().uuidString
        let item = ProxyItem(targetURL: targetURL, headers: headers)
        proxyLock.withLock { proxyItems[proxyId] = item }
        return URL(string: "http://\(localIP):\(port)/proxy/\(proxyId)")
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

            // Time-based seek: ?t=<seconds> — build a self-contained MP4 from the
            // keyframe byte offset so the TV receives a valid stream with moov header.
            if let tParam = request.queryParams.first(where: { $0.0 == "t" })?.1,
               let seconds = Double(tParam), seconds > 0 {
                if let prelude = MP4SeekParser.buildSeekPrelude(for: seconds, in: fileURL) {
                    return Self.seekResponse(path: path, mime: mime, prelude: prelude,
                                             rangeHeader: request.headers["range"])
                }
            }

            // Range header always takes priority — Samsung uses it for buffering.
            if let rangeHeader = request.headers["range"] {
                return Self.rangeResponse(path: path, fileSize: fileSize,
                                          mime: mime, rangeHeader: rangeHeader)
            } else {
                return Self.fullResponse(path: path, fileSize: fileSize, mime: mime)
            }
        }

        // CDN proxy: TV requests /proxy/<id> → phone fetches from CDN with stored headers.
        // Samsung sends Range requests (small chunks), so buffering per request is fine.
        server["/proxy/:proxyId"] = { [proxyLock, weak self] request in
            guard let self else { return .notFound }
            let proxyId = request.params[":proxyId"] ?? ""
            guard let item = proxyLock.withLock({ self.proxyItems[proxyId] }) else {
                return .notFound
            }

            var cdnReq = URLRequest(url: item.targetURL, timeoutInterval: 30)
            for (k, v) in item.headers { cdnReq.setValue(v, forHTTPHeaderField: k) }
            if let range = request.headers["range"] {
                cdnReq.setValue(range, forHTTPHeaderField: "Range")
            }

            let sem = DispatchSemaphore(value: 0)
            var cdnStatus = 200
            var cdnHeaders: [String: String] = [:]
            var cdnData = Data()

            URLSession.shared.dataTask(with: cdnReq) { data, response, _ in
                if let http = response as? HTTPURLResponse {
                    cdnStatus = http.statusCode
                    for (k, v) in http.allHeaderFields {
                        if let key = k as? String, let val = v as? String {
                            cdnHeaders[key] = val
                        }
                    }
                }
                cdnData = data ?? Data()
                sem.signal()
            }.resume()
            sem.wait()

            // Pass through only safe headers; always add DLNA streaming hints.
            var outHeaders = Self.dlnaHeaders
            outHeaders["Content-Type"]   = cdnHeaders["Content-Type"]  ?? "video/mp4"
            outHeaders["Content-Length"] = cdnHeaders["Content-Length"] ?? "\(cdnData.count)"
            outHeaders["Accept-Ranges"]  = "bytes"
            if let cr = cdnHeaders["Content-Range"] { outHeaders["Content-Range"] = cr }

            let statusMsg = cdnStatus == 206 ? "Partial Content" : "OK"
            let captured = cdnData
            return .raw(cdnStatus, statusMsg, outHeaders) { writer in
                try? writer.write(captured)
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

    /// Serves a synthesised, seek-adjusted MP4 stream:
    ///   [ftyp (if present)] [moov with patched stco/co64] [mdat header] [file data from keyframe offset …]
    /// The TV receives a fully valid MP4 starting at the requested keyframe.
    /// Supports Range requests so Samsung's buffering connections get proper 206 responses
    /// instead of 200, eliminating repeated connect-drop cycles.
    private static func seekResponse(
        path: String, mime: String, prelude: MP4SeekParser.SeekPrelude,
        rangeHeader: String? = nil
    ) -> HttpResponse {
        guard let fh = FileHandle(forReadingAtPath: path) else { return .internalServerError }

        // Build the in-memory header region: [ftyp] [moov] [mdat box header (8 bytes)]
        var headerData = Data()
        headerData.append(prelude.ftypData)
        headerData.append(prelude.moovData)
        var mdatHdr = Data(count: 8)
        let mdatBoxSize = 8 + prelude.dataLength
        mdatHdr.writeU32(UInt32(min(mdatBoxSize, UInt64(UInt32.max))), at: 0)
        mdatHdr[4] = UInt8(ascii: "m"); mdatHdr[5] = UInt8(ascii: "d")
        mdatHdr[6] = UInt8(ascii: "a"); mdatHdr[7] = UInt8(ascii: "t")
        headerData.append(mdatHdr)

        let headerSize = UInt64(headerData.count)
        let totalLength = headerSize + prelude.dataLength

        // Resolve byte range (full content if no Range header).
        let (rangeStart, rangeEnd) = rangeHeader.map { parseRange($0, fileSize: totalLength) }
                                     ?? (0, totalLength - 1)
        let serveLength = rangeEnd - rangeStart + 1
        let isRange = rangeHeader != nil

        var headers = dlnaHeaders
        headers["Content-Type"]   = mime
        headers["Content-Length"] = "\(serveLength)"
        headers["Accept-Ranges"]  = "bytes"
        if isRange {
            headers["Content-Range"] = "bytes \(rangeStart)-\(rangeEnd)/\(totalLength)"
        }

        return .raw(isRange ? 206 : 200, isRange ? "Partial Content" : "OK", headers) { writer in
            defer { fh.closeFile() }
            do {
                var bytesWritten: UInt64 = 0

                // ── Serve bytes from the in-memory header region ──────────────────
                if rangeStart < headerSize {
                    let sliceStart = Int(rangeStart)
                    let sliceEnd   = Int(min(headerSize - 1, rangeEnd))
                    try writer.write(Data(headerData[sliceStart...sliceEnd]))
                    bytesWritten += UInt64(sliceEnd - sliceStart + 1)
                }

                // ── Serve bytes from the file (video data after the keyframe) ─────
                if rangeEnd >= headerSize {
                    let fileRangeStart = max(rangeStart, headerSize)
                    let fileOffset     = prelude.dataOffset + (fileRangeStart - headerSize)
                    fh.seek(toFileOffset: fileOffset)
                    var leftToRead = serveLength - bytesWritten
                    let chunkSize  = 256 * 1024
                    while leftToRead > 0 {
                        let toRead = Int(min(UInt64(chunkSize), leftToRead))
                        let chunk  = fh.readData(ofLength: toRead)
                        guard !chunk.isEmpty else { break }
                        try writer.write(chunk)
                        leftToRead -= UInt64(chunk.count)
                    }
                }
            } catch {
                print(">>> HTTPServer seekResponse write error: \(error)")
            }
        }
    }

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
