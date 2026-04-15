import Foundation

// MARK: - Model

struct UPnPDevice: Identifiable, Hashable {
    let id: String           // USN
    let friendlyName: String
    let location: String
    var avTransportControlURL: String?
    var renderingControlURL: String?

    static func == (lhs: UPnPDevice, rhs: UPnPDevice) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Creates a Samsung device with control URLs pinned to port 9197.
    ///
    /// Samsung TVs expose UPnP on several ports (8187, 7678, 8080, …) but only port 9197
    /// accepts AVTransport/RenderingControl commands. Other ports return error 402 on all actions.
    static func manual(ip: String) -> UPnPDevice {
        UPnPDevice(
            id: "manual:\(ip)",
            friendlyName: "Samsung TV",
            location: "http://\(ip):55000",
            avTransportControlURL: "http://\(ip):9197/upnp/control/AVTransport1",
            renderingControlURL: "http://\(ip):9197/upnp/control/RenderingControl1"
        )
    }
}

// MARK: - XML Parser

final class DeviceDescriptionParser: NSObject, XMLParserDelegate {
    private(set) var device: UPnPDevice?

    private let usn: String
    private let location: String

    private var currentElement = ""
    private var currentValue = ""

    // Device-level fields
    private var friendlyName = ""
    private var urlBase = ""

    // Service-level fields
    private var inService = false
    private var currentServiceType = ""
    private var currentControlURL = ""
    private var avTransportControlURL: String?
    private var renderingControlURL: String?

    init(usn: String, location: String) {
        self.usn = usn
        self.location = location
    }

    func parse(data: Data) {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()

        let base = urlBase.isEmpty ? Self.baseFromLocation(location) : urlBase

        device = UPnPDevice(
            id: usn,
            friendlyName: friendlyName.isEmpty ? "Unknown Device" : friendlyName,
            location: location,
            avTransportControlURL: avTransportControlURL.map { Self.absoluteURL($0, base: base) },
            renderingControlURL: renderingControlURL.map { Self.absoluteURL($0, base: base) }
        )
    }

    // MARK: - Helpers

    private static func baseFromLocation(_ location: String) -> String {
        guard let url = URL(string: location) else { return "" }
        let scheme = url.scheme ?? "http"
        let host = url.host ?? ""
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)"
    }

    private static func absoluteURL(_ path: String, base: String) -> String {
        path.hasPrefix("http") ? path : base + path
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName _: String?,
                attributes _: [String: String] = [:]) {
        currentElement = elementName
        currentValue = ""
        if elementName == "service" {
            inService = true
            currentServiceType = ""
            currentControlURL = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI _: String?,
                qualifiedName _: String?) {
        let value = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)

        switch elementName {
        case "friendlyName":
            friendlyName = value
        case "URLBase":
            urlBase = value
        case "serviceType":
            currentServiceType = value
        case "controlURL":
            currentControlURL = value
        case "service":
            if inService {
                if currentServiceType.contains("AVTransport") {
                    avTransportControlURL = currentControlURL
                } else if currentServiceType.contains("RenderingControl") {
                    renderingControlURL = currentControlURL
                }
                inService = false
            }
        default:
            break
        }

        currentElement = ""
        currentValue = ""
    }
}
