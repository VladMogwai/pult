import Combine
import Darwin
import Foundation

// MARK: - SSDPDiscovery

@MainActor
final class SSDPDiscovery: ObservableObject {
    @Published private(set) var devices: [UPnPDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var scanProgress: Double = 0

    private var ssdpTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?

    // MARK: - Public

    /// Runs one SSDP cycle + one subnet scan, then stops completely.
    /// Safe to call multiple times — cancels any in-progress scan first.
    func startDiscovery() {
        stopDiscovery()
        ssdpTask = Task { [weak self] in
            await self?.performDiscoveryCycle()
        }
        startSubnetScan()
    }

    func stopDiscovery() {
        ssdpTask?.cancel()
        ssdpTask = nil
        stopSubnetScan()
    }

    /// Stops all background scanning — call once the user has selected a device.
    func stopAllScanning() {
        stopDiscovery()
    }

    func clearAndRediscover() {
        devices.removeAll()
        startDiscovery()
    }

    func addDevice(_ device: UPnPDevice) {
        guard !devices.contains(where: { $0.id == device.id }) else { return }
        devices.append(device)
    }

    /// Directly probes a previously-known device location so auto-connect works
    /// even when the general scan misses it (e.g. another device is found first).
    func probeKnownDevice(location: String) {
        guard let ip = URL(string: location)?.host else { return }
        Task { [weak self] in
            if let device = await Self.probeHost(ip: ip) {
                await MainActor.run { self?.addDevice(device) }
            }
        }
    }

    // MARK: - Subnet scan

    private func startSubnetScan() {
        stopSubnetScan()
        isScanning = true
        scanProgress = 0
        scanTask = Task { [weak self] in
            await self?.performSubnetScan()
            await MainActor.run { self?.isScanning = false }
        }
    }

    private func stopSubnetScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private func performSubnetScan() async {
        guard let localIP = NetworkHelper.getLocalIPAddress() else { return }
        let hosts = Self.subnetHosts(from: localIP)
        guard !hosts.isEmpty else { return }

        let total = Double(hosts.count)
        var completed = 0.0

        // Hard 15-second timeout: cancel the whole scan regardless of progress.
        let deadline = Task {
            try? await Task.sleep(for: .seconds(15))
        }

        await withTaskGroup(of: UPnPDevice?.self) { group in
            var inFlight = 0
            let maxConcurrent = 10

            for ip in hosts {
                if Task.isCancelled || deadline.isCancelled { break }

                if inFlight >= maxConcurrent {
                    if let found = await group.next() {
                        if let device = found {
                            addDevice(device)
                            // Cancel remaining scan once we have a result.
                            group.cancelAll()
                            deadline.cancel()
                            break
                        }
                    }
                    completed += 1
                    scanProgress = completed / total
                    inFlight -= 1
                }

                group.addTask { await Self.probeHost(ip: ip) }
                inFlight += 1
            }

            // Drain remaining in-flight probes (respects cancellation).
            for await found in group {
                if let device = found {
                    addDevice(device)
                    group.cancelAll()
                    deadline.cancel()
                    break
                }
                completed += 1
                scanProgress = completed / total
            }
        }

        deadline.cancel()

        // Mark progress complete whether we finished or were cancelled.
        scanProgress = 1.0
    }

    // MARK: - Probe helpers (nonisolated — run off the main actor)

    private nonisolated static func subnetHosts(from ip: String) -> [String] {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return [] }
        let prefix = "\(parts[0]).\(parts[1]).\(parts[2])"
        return (1...254).map { "\(prefix).\($0)" }
    }

    /// Probes all candidate ports for a single host concurrently; returns on first hit.
    private nonisolated static func probeHost(ip: String) async -> UPnPDevice? {
        let ports = [9197, 7678, 8187, 8080]
        return await withTaskGroup(of: UPnPDevice?.self) { group in
            for port in ports {
                group.addTask { await probePort(ip: ip, port: port) }
            }
            for await result in group {
                if let device = result {
                    group.cancelAll()
                    return device
                }
            }
            return nil
        }
    }

    private nonisolated static func probePort(ip: String, port: Int) async -> UPnPDevice? {
        guard let url = URL(string: "http://\(ip):\(port)/upnp/control/AVTransport1") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 0.5)
        request.httpMethod = "GET"
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let body = String(data: data, encoding: .utf8),
            body.contains("Envelope")
        else { return nil }

        // Pin control URLs to port 9197 — the port that responded to the probe is used
        // only for device detection; Samsung ignores AVTransport commands on other ports.
        return UPnPDevice(
            id: "scan:\(ip)",
            friendlyName: "Samsung TV (\(ip))",
            location: "http://\(ip):\(port)",
            avTransportControlURL: "http://\(ip):9197/upnp/control/AVTransport1",
            renderingControlURL:   "http://\(ip):9197/upnp/control/RenderingControl1"
        )
    }

    // MARK: - SSDP discovery cycle (runs once)

    private func performDiscoveryCycle() async {
        let responses = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let results = SSDPSocket.sendMSearch()
                continuation.resume(returning: results)
            }
        }

        for entry in responses {
            guard !devices.contains(where: { $0.id == entry.usn }) else { continue }
            if let device = await fetchDevice(usn: entry.usn, location: entry.location) {
                if !devices.contains(where: { $0.id == device.id }) {
                    devices.append(device)
                }
            }
        }
    }

    private func fetchDevice(usn: String, location: String) async -> UPnPDevice? {
        guard let url = URL(string: location) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let parser = DeviceDescriptionParser(usn: usn, location: location)
            parser.parse(data: data)
            return parser.device
        } catch {
            return UPnPDevice(
                id: usn,
                friendlyName: "Device (\(URL(string: location)?.host ?? "unknown"))",
                location: location
            )
        }
    }
}

// MARK: - Low-level SSDP socket (runs on a background DispatchQueue)

private enum SSDPSocket {
    private static let multicastAddress = "239.255.255.250"
    private static let multicastPort: Int32 = 1900

    struct Entry { let usn: String; let location: String }

    /// Sends an M-SEARCH multicast and collects responses for 3 seconds.
    static func sendMSearch() -> [Entry] {
        let sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return [] }
        defer { Darwin.close(sock) }

        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var ttl: UInt8 = 4
        setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, socklen_t(MemoryLayout<UInt8>.size))

        var tv = timeval(); tv.tv_sec = 3; tv.tv_usec = 0
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = 0
        bindAddr.sin_addr.s_addr = INADDR_ANY
        let bindResult = withUnsafeMutablePointer(to: &bindAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return [] }

        let message = [
            "M-SEARCH * HTTP/1.1",
            "HOST: \(multicastAddress):\(multicastPort)",
            "MAN: \"ssdp:discover\"",
            "MX: 3",
            "ST: urn:schemas-upnp-org:device:MediaRenderer:1",
            "", ""
        ].joined(separator: "\r\n")

        guard let msgData = message.data(using: .utf8) else { return [] }

        var destAddr = sockaddr_in()
        destAddr.sin_family = sa_family_t(AF_INET)
        destAddr.sin_port = UInt16(bitPattern: Int16(multicastPort)).bigEndian
        destAddr.sin_addr.s_addr = inet_addr(multicastAddress)

        msgData.withUnsafeBytes { bytes in
            withUnsafeMutablePointer(to: &destAddr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(sock, bytes.baseAddress, msgData.count, 0,
                               sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var results: [Entry] = []
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let n = recv(sock, &buffer, buffer.count - 1, 0)
            guard n > 0 else { break }
            let text = String(bytes: buffer.prefix(n), encoding: .utf8) ?? ""
            if let entry = parseResponse(text) {
                if !results.contains(where: { $0.usn == entry.usn }) {
                    results.append(entry)
                }
            }
        }

        return results
    }

    private static func parseResponse(_ response: String) -> Entry? {
        var location: String?
        var usn: String?

        for line in response.components(separatedBy: "\r\n") {
            let lower = line.lowercased()
            if lower.hasPrefix("location:") {
                location = String(line.dropFirst("location:".count)).trimmingCharacters(in: .whitespaces)
            } else if lower.hasPrefix("usn:") {
                usn = String(line.dropFirst("usn:".count)).trimmingCharacters(in: .whitespaces)
            }
        }

        guard let loc = location, !loc.isEmpty,
              let id = usn, !id.isEmpty else { return nil }
        return Entry(usn: id, location: loc)
    }
}
