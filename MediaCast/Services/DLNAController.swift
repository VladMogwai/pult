import Combine
import Foundation

// MARK: - DLNAController

@MainActor
final class DLNAController: ObservableObject {

    // MARK: - Published state

    @Published private(set) var transportState: TransportState = .stopped
    @Published private(set) var currentPosition: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var volume: Int = 50
    /// True while the stream is fake-paused (stopped on TV, position saved locally).
    @Published private(set) var isPaused: Bool = false

    // MARK: - Private

    private(set) var selectedDevice: UPnPDevice?
    private var pollingTask: Task<Void, Never>?
    /// Retained so seek / resume can replay the full SetURI → Play → Seek sequence.
    private(set) var currentVideoURL: URL?
    /// Position captured on fake pause; cleared on resume or stop.
    private var pausedPosition: TimeInterval?

    // MARK: - Device selection

    func selectDevice(_ device: UPnPDevice) {
        selectedDevice = device
    }

    // MARK: - AVTransport Actions

    func setAVTransportURI(videoURL: URL) async throws {
        pausePolling()
        // Strip any query params so currentVideoURL is always a clean base URL.
        var comps = URLComponents(url: videoURL, resolvingAgainstBaseURL: false)
        comps?.queryItems = nil
        currentVideoURL = comps?.url ?? videoURL

        let controlURL = try avTransportURL()
        let escapedURI = xmlEscape(videoURL.absoluteString)
        let title = xmlEscape(videoURL.deletingPathExtension().lastPathComponent)

        let didl = """
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">
          <item id="0" parentID="-1" restricted="1">
            <dc:title>\(title)</dc:title>
            <upnp:class>object.item.videoItem</upnp:class>
            <res protocolInfo="http-get:*:video/mp4:*">\(escapedURI)</res>
          </item>
        </DIDL-Lite>
        """
        let escapedDidl = xmlEscape(didl)

        let body = """
        <InstanceID>0</InstanceID>
        <CurrentURI>\(escapedURI)</CurrentURI>
        <CurrentURIMetaData>\(escapedDidl)</CurrentURIMetaData>
        """
        try await soap(url: controlURL, service: "AVTransport", action: "SetAVTransportURI", body: body)

        // Samsung needs a moment to parse and buffer the URI before it will accept Play.
        try await Task.sleep(for: .seconds(1))
    }

    private func xmlEscape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&",  with: "&amp;")
            .replacingOccurrences(of: "<",  with: "&lt;")
            .replacingOccurrences(of: ">",  with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'",  with: "&apos;")
    }

    func play() async throws {
        pausePolling()
        if let saved = pausedPosition {
            // Resume from fake pause (Stop fallback): SetAVTransportURI → Play → Seek.
            guard let videoURL = currentVideoURL else { return }
            pausedPosition = nil
            isPaused = false
            try await setAVTransportURI(videoURL: videoURL)  // includes 1 s load delay
            try await sendPlay()
            transportState = .playing
            do {
                try await waitUntilPlaying()
                try await sendSeekSOAP(to: saved)
                currentPosition = saved
                print(">>> resume: seeked to \(formatTime(saved))")
            } catch {
                print(">>> resume: Seek failed (\(error)) — playing from start")
            }
            resumePolling()
        } else {
            // Resume from real UPnP Pause, or start from stopped state.
            isPaused = false
            try await sendPlay()
            transportState = .playing
            resumePolling()
        }
    }

    func pause() async throws {
        pausePolling()
        print(">>> pause() — transportState=\(transportState)")
        let controlURL = try avTransportURL()
        do {
            try await soap(url: controlURL, service: "AVTransport", action: "Pause",
                           body: "<InstanceID>0</InstanceID>")
            // Real UPnP Pause accepted — renderer remembers position in PAUSED_PLAYBACK.
            isPaused = true
            pausedPosition = nil
            transportState = .paused
            print(">>> pause: UPnP Pause accepted")
        } catch let error as DLNAError {
            guard case .soapFault(_, let xml) = error,
                  extractXML(xml, tag: "errorCode") == "501" else { throw error }
            // Renderer returned 501 Not Implemented — fall back to fake pause.
            print(">>> pause: Pause returned 501, falling back to Stop + saved position")
            try await getPositionInfo()
            let saved = currentPosition
            print(">>> pause: saved position=\(formatTime(saved))")
            try await soap(url: controlURL, service: "AVTransport", action: "Stop",
                           body: "<InstanceID>0</InstanceID>")
            pausedPosition = saved
            currentPosition = saved
            isPaused = true
            transportState = .paused
        }
        // Polling intentionally not resumed — TV is paused/stopped until play() is called.
    }

    func stop() async throws {
        pausePolling()
        let controlURL = try avTransportURL()
        try await soap(url: controlURL, service: "AVTransport", action: "Stop",
                       body: "<InstanceID>0</InstanceID>")
        pausedPosition = nil
        isPaused = false
        transportState = .stopped
        currentPosition = 0
        // Polling intentionally not resumed — TV is stopped.
    }

    func seek(to position: TimeInterval) async throws {
        pausePolling()
        print(">>> seek: from=\(formatTime(currentPosition)) to=\(formatTime(position))")
        let wasPlaying = transportState == .playing
        pausedPosition = nil  // discard any fake-pause marker
        try await sendSeekSOAP(to: position)
        currentPosition = position
        // Re-send Play after seek — some renderers pause during the seek operation.
        if wasPlaying {
            try await sendPlay()
        }
        print(">>> seek: complete — position=\(formatTime(position))")
        resumePolling()
    }

    // MARK: - Seek diagnostic

    /// Automated seek test: waits 3 s after play then seeks to 1:00.
    /// Call immediately after play() succeeds in the cast flow to isolate timing issues.
    func testSeek() async {
        print(">>> testSeek: waiting 3 s after play")
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        print(">>> testSeek: firing seek(to: 60) — transportState=\(transportState) duration=\(duration) currentVideoURL=\(currentVideoURL?.absoluteString ?? "nil")")
        do {
            try await seek(to: 60)
            print(">>> testSeek: seek completed — currentPosition=\(currentPosition)")
        } catch {
            print(">>> testSeek: seek failed — \(error)")
        }
    }

    // MARK: - Raw SOAP helpers

    /// Polls GetTransportInfo every 300 ms until the renderer reaches PLAYING state.
    /// Throws `DLNAError.transitionTimeout` if `timeout` seconds elapse first.
    /// Call this after every Play SOAP action and before any follow-up Seek,
    /// because renderers return 701 when they are still in TRANSITIONING state.
    private func waitUntilPlaying(timeout: TimeInterval = 3.0) async throws {
        let pollInterval = Duration.milliseconds(300)
        let maxSteps = Int(timeout / 0.3)
        for step in 1...maxSteps {
            try await Task.sleep(for: pollInterval)
            let controlURL = try avTransportURL()
            let xml = try await soapResponse(url: controlURL, service: "AVTransport",
                                             action: "GetTransportInfo",
                                             body: "<InstanceID>0</InstanceID>")
            let state = extractXML(xml, tag: "CurrentTransportState") ?? "UNKNOWN"
            print(">>> waitUntilPlaying [\(step)/\(maxSteps)]: state=\(state)")
            if state == "PLAYING" { return }
        }
        throw DLNAError.transitionTimeout
    }

    private func sendPlay() async throws {
        let controlURL = try avTransportURL()
        try await soap(url: controlURL, service: "AVTransport",
                       action: "Play", body: "<InstanceID>0</InstanceID><Speed>1</Speed>")
    }

    /// Sends Seek REL_TIME SOAP action to the TV.
    private func sendSeekSOAP(to position: TimeInterval) async throws {
        let controlURL = try avTransportURL()
        let timeStr = formatTime(position)
        print(">>> sendSeekSOAP: target=\(timeStr)")
        let body = """
        <InstanceID>0</InstanceID>
        <Unit>REL_TIME</Unit>
        <Target>\(timeStr)</Target>
        """
        try await soap(url: controlURL, service: "AVTransport", action: "Seek", body: body)
    }

    // MARK: - Polling (GetTransportInfo + GetPositionInfo)

    private func getTransportInfo() async throws {
        let controlURL = try avTransportURL()
        let xml = try await soapResponse(url: controlURL, service: "AVTransport",
                                         action: "GetTransportInfo",
                                         body: "<InstanceID>0</InstanceID>")
        let stateStr = extractXML(xml, tag: "CurrentTransportState") ?? "STOPPED"
        transportState = TransportState(rawValue: stateStr) ?? .stopped
    }

    private func getPositionInfo() async throws {
        let controlURL = try avTransportURL()
        let xml = try await soapResponse(url: controlURL, service: "AVTransport",
                                         action: "GetPositionInfo",
                                         body: "<InstanceID>0</InstanceID>")
        let posStr = extractXML(xml, tag: "RelTime") ?? "00:00:00"
        let durStr = extractXML(xml, tag: "TrackDuration") ?? "00:00:00"
        currentPosition = parseTime(posStr)
        let dur = parseTime(durStr)
        if dur > 0 { duration = dur }
    }

    // MARK: - RenderingControl Actions

    func setVolume(_ newVolume: Int) async throws {
        guard let device = selectedDevice,
              let controlURL = device.renderingControlURL else {
            throw DLNAError.noDevice
        }
        let clamped = max(0, min(100, newVolume))
        let body = """
        <InstanceID>0</InstanceID>
        <Channel>Master</Channel>
        <DesiredVolume>\(clamped)</DesiredVolume>
        """
        try await soap(url: controlURL, service: "RenderingControl", action: "SetVolume", body: body)
        volume = clamped
    }

    // MARK: - Polling management

    /// Cancels any in-flight poll synchronously.
    /// Must be called before every SOAP control action to prevent the TV
    /// from receiving parallel requests (returns 701 "Transition not available").
    func pausePolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Restarts the polling loop after a control action completes.
    func resumePolling() {
        startPolling()
    }

    func startPolling() {
        pausePolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                try? await self?.getPositionInfo()
                try? await self?.getTransportInfo()
            }
        }
    }

    func stopPolling() {
        pausePolling()
    }

    // MARK: - SOAP

    private func avTransportURL() throws -> String {
        guard let device = selectedDevice else { throw DLNAError.noDevice }
        guard let url = device.avTransportControlURL else { throw DLNAError.missingControlURL }
        return url
    }

    @discardableResult
    private func soap(url: String, service: String, action: String, body: String) async throws -> Data {
        return try await sendSOAP(url: url, service: service, action: action, body: body)
    }

    private func soapResponse(url: String, service: String, action: String, body: String) async throws -> String {
        let data = try await sendSOAP(url: url, service: service, action: action, body: body)
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func sendSOAP(url: String, service: String, action: String, body: String) async throws -> Data {
        guard let endpoint = URL(string: url) else { throw DLNAError.invalidURL }

        let urn = "urn:schemas-upnp-org:service:\(service):1"
        let envelope = """
        <?xml version="1.0"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
        s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(urn)">
              \(body)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\"\(urn)#\(action)\"", forHTTPHeaderField: "SOAPACTION")
        request.httpBody = envelope.data(using: .utf8)

        print("""
        ── SOAP REQUEST ───────────────────────────────────────────
        \(action) → \(url)
        SOAPACTION: "\(urn)#\(action)"
        \(envelope)
        ───────────────────────────────────────────────────────────
        """)

        let (data, response) = try await URLSession.shared.data(for: request)
        let responseBody = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

        print("""
        ── SOAP RESPONSE ──────────────────────────────────────────
        \(action) ← HTTP \(statusCode)
        \(responseBody)
        ───────────────────────────────────────────────────────────
        """)

        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            throw DLNAError.soapFault(statusCode: statusCode, xml: responseBody)
        }
        return data
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    private func parseTime(_ string: String) -> TimeInterval {
        let parts = string.components(separatedBy: ":").compactMap(Double.init)
        guard parts.count == 3 else { return 0 }
        return parts[0] * 3600 + parts[1] * 60 + parts[2]
    }

    private func extractXML(_ xml: String, tag: String) -> String? {
        guard let start = xml.range(of: "<\(tag)>"),
              let end = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex)
        else { return nil }
        return String(xml[start.upperBound..<end.lowerBound])
    }
}

// MARK: - TransportState

enum TransportState: String {
    case playing = "PLAYING"
    case paused = "PAUSED_PLAYBACK"
    case stopped = "STOPPED"
    case transitioning = "TRANSITIONING"
    case noMediaPresent = "NO_MEDIA_PRESENT"

    var displayName: String {
        switch self {
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        case .transitioning: return "Loading…"
        case .noMediaPresent: return "No Media"
        }
    }
}

// MARK: - Errors

enum DLNAError: LocalizedError {
    case noDevice
    case missingControlURL
    case invalidURL
    case soapFault(statusCode: Int, xml: String)
    case transitionTimeout

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No device selected. Go to the Devices tab and pick a TV."
        case .missingControlURL:
            return "Device does not expose a control URL."
        case .invalidURL:
            return "Control URL is malformed."
        case .transitionTimeout:
            return "TV did not reach PLAYING state within 3 seconds."
        case .soapFault(let statusCode, let xml):
            // Extract the human-readable fault string from the SOAP envelope if present,
            // otherwise fall back to the raw XML so the full response is always visible.
            let faultString = Self.extractFaultString(from: xml)
            let preview = faultString ?? xml
            return "TV returned HTTP \(statusCode):\n\(preview)"
        }
    }

    /// Pulls <faultstring> or <errorDescription> out of a SOAP fault envelope.
    private static func extractFaultString(from xml: String) -> String? {
        for tag in ["faultstring", "errorDescription", "errorCode"] {
            if let start = xml.range(of: "<\(tag)>"),
               let end   = xml.range(of: "</\(tag)>", range: start.upperBound..<xml.endIndex) {
                let value = String(xml[start.upperBound..<end.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { return value }
            }
        }
        return nil
    }
}
