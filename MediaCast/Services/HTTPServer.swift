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
        BackgroundKeepAlive.shared.start()
    }

    func stop() {
        server.stop()
        fileLock.withLock { servedFiles.removeAll() }
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
        BackgroundKeepAlive.shared.stop()
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
        print("[MC-DIAG] HTTPServer.addProxy id=\(proxyId)")
        print("[MC-DIAG]   target=\(targetURL.absoluteString.prefix(120))")
        print("[MC-DIAG]   headers=\(headers)")
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

        // SEEK FIX: Replace buffered dataTask with URLSessionDataDelegate so CDN errors,
        // HTTP/2 lowercase headers, and non-206 status codes are propagated correctly.
        server["/proxy/:proxyId"] = { [proxyLock, weak self] request in
            guard let self else { return .notFound }
            let proxyId = request.params[":proxyId"] ?? ""
            guard let item = proxyLock.withLock({ self.proxyItems[proxyId] }) else {
                print("[MC-DIAG] HTTPServer proxy unknown id=\(proxyId)")
                return .notFound
            }

            print("[MC-DIAG] HTTPServer proxy incoming: id=\(proxyId.prefix(8)) range=\(request.headers["range"] ?? "none") ua=\(request.headers["user-agent"]?.prefix(60) ?? "none")")

            var cdnReq = URLRequest(url: item.targetURL, timeoutInterval: 30)
            for (k, v) in item.headers { cdnReq.setValue(v, forHTTPHeaderField: k) }
            if let range = request.headers["range"] {
                cdnReq.setValue(range, forHTTPHeaderField: "Range")
            }

            print("[MC-DIAG] HTTPServer proxy CDN request: \(item.targetURL.absoluteString.prefix(120))")

            // SEEK FIX: Delegate-based session surfaces errors as non-200 status codes
            // instead of silently returning 200 OK with an empty body.
            let collector = CDNResponseCollector()
            let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: nil)
            session.dataTask(with: cdnReq).resume()

            // SEEK FIX: Return 504 if CDN doesn't respond in time rather than hanging forever.
            guard collector.awaitHeaders(timeout: 15) else {
                session.invalidateAndCancel()
                print("[MC-DIAG] HTTPServer proxy CDN timeout (15s) id=\(proxyId.prefix(8))")
                return .raw(504, "Gateway Timeout", [:]) { _ in }
            }

            let cdnStatus  = collector.statusCode
            // SEEK FIX: All header keys are lowercased so HTTP/2 headers are found correctly.
            let cdnHeaders = collector.normalizedHeaders

            print("[MC-DIAG] HTTPServer proxy CDN response: status=\(cdnStatus) content-type=\(cdnHeaders["content-type"] ?? "?") content-length=\(cdnHeaders["content-length"] ?? "?") content-range=\(cdnHeaders["content-range"] ?? "none")")
            if cdnStatus >= 400 {
                print("[MC-DIAG] HTTPServer proxy CDN ERROR status=\(cdnStatus) url=\(item.targetURL.absoluteString.prefix(120))")
            }

            var outHeaders = Self.dlnaHeaders
            outHeaders["Content-Type"]  = cdnHeaders["content-type"] ?? "video/mp4"
            outHeaders["Accept-Ranges"] = "bytes"
            // SEEK FIX: content-length was silently dropped because HTTP/2 sends it lowercase.
            if let cl = cdnHeaders["content-length"] { outHeaders["Content-Length"] = cl }
            // SEEK FIX: content-range is required so Samsung can compute seek byte offsets.
            if let cr = cdnHeaders["content-range"]  { outHeaders["Content-Range"]  = cr }

            // SEEK FIX: Return the real CDN status code and a matching reason phrase
            // instead of always returning "OK" for non-206 responses.
            return .raw(cdnStatus, Self.reasonPhrase(cdnStatus), outHeaders) { writer in
                collector.awaitBodyAndWrite(to: writer)
                session.finishTasksAndInvalidate()
            }
        }
    }

    // MARK: - CDN response collector

    /// Two-phase URLSessionDataDelegate:
    ///   Phase 1 — captures status code + headers, signals headersSem.
    ///   Phase 2 — accumulates body chunks; signals doneSem on completion.
    ///
    /// SEEK FIX: Replaces the old dataTask completion handler that (a) ignored the
    /// error parameter, (b) did case-sensitive header lookup that missed HTTP/2 lowercase
    /// keys, and (c) returned "OK" as the reason phrase for every non-206 response.
    private final class CDNResponseCollector: NSObject, URLSessionDataDelegate {
        private let headersSem = DispatchSemaphore(value: 0)
        private let doneSem    = DispatchSemaphore(value: 0)
        private let lock       = NSLock()

        private(set) var statusCode: Int = 502
        /// All header names are lowercased so HTTP/2 headers are found correctly.
        private(set) var normalizedHeaders: [String: String] = [:]
        private var bodyChunks: [Data] = []
        private var headersSignalled = false

        func urlSession(_ session: URLSession,
                        dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse {
                statusCode = http.statusCode
                for (k, v) in http.allHeaderFields {
                    if let key = k as? String, let val = v as? String {
                        normalizedHeaders[key.lowercased()] = val
                    }
                }
            }
            lock.withLock {
                if !headersSignalled { headersSignalled = true; headersSem.signal() }
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.withLock { bodyChunks.append(data) }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { print(">>> CDN proxy error: \(error)") }
            // Signal headers if the request failed before any response arrived.
            lock.withLock {
                if !headersSignalled { headersSignalled = true; headersSem.signal() }
            }
            doneSem.signal()
        }

        /// Returns false on timeout (CDN did not respond within `timeout` seconds).
        func awaitHeaders(timeout: TimeInterval) -> Bool {
            headersSem.wait(timeout: .now() + timeout) == .success
        }

        /// Blocks until the CDN transfer completes, then writes all body data to `writer`.
        func awaitBodyAndWrite(to writer: HttpResponseBodyWriter) {
            doneSem.wait()
            let chunks = lock.withLock { bodyChunks }
            for chunk in chunks { try? writer.write(chunk) }
        }
    }

    // MARK: - Response helpers

    private static func reasonPhrase(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default:  return "Unknown"
        }
    }

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
