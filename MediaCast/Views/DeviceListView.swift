import SwiftUI

struct DeviceListView: View {
    @ObservedObject var ssdp: SSDPDiscovery
    @Binding var selectedDevice: UPnPDevice?

    @State private var showingManualEntry = false

    var body: some View {
        NavigationView {
            Group {
                if ssdp.devices.isEmpty {
                    emptyView
                } else {
                    List {
                        ForEach(ssdp.devices) { device in
                            DeviceRow(device: device, isSelected: selectedDevice?.id == device.id)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedDevice = device }
                        }
                        if ssdp.isScanning {
                            scanFooter
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Devices")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if ssdp.isScanning {
                        ProgressView()
                    } else {
                        Button {
                            ssdp.clearAndRediscover()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add manually") {
                        showingManualEntry = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingManualEntry) {
            ManualDeviceSheet { device in
                ssdp.addDevice(device)
                selectedDevice = device
            }
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private var emptyView: some View {
        if ssdp.isScanning {
            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.5)

                Text("Scanning network…")
                    .font(.headline)

                Text("Listening for UPnP renderers via SSDP multicast")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            ContentUnavailableView {
                Label("No Devices Found", systemImage: "tv.slash")
            } description: {
                Text("No UPnP renderers were found on your network.")
            } actions: {
                Button("Scan Again") { ssdp.clearAndRediscover() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private var scanFooter: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
            Text("Scanning for more devices…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .listRowBackground(Color.clear)
        .padding(.vertical, 8)
    }
}

// MARK: - ManualDeviceSheet

private struct ManualDeviceSheet: View {
    let onAdd: (UPnPDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ipAddress = ""
    @State private var isProbing = false
    @State private var errorMessage: String?

    private let probePorts: [Int] = [55000, 7676, 8080]
    private let probePaths = ["/dmr", "/description.xml"]

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("IP address (e.g. 192.168.1.100)", text: $ipAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("TV IP Address")
                } footer: {
                    Text("Port defaults to 55000 (Samsung). Fallbacks: 7676, 8080.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isProbing {
                        ProgressView()
                    } else {
                        Button("Connect") {
                            Task { await probe() }
                        }
                        .disabled(ipAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }
    }

    private func probe() async {
        let ip = ipAddress.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        isProbing = true
        errorMessage = nil

        if let device = await probeDevice(ip: ip) {
            isProbing = false
            onAdd(device)
            dismiss()
        } else {
            // Probe failed — fall back to known Samsung defaults
            isProbing = false
            onAdd(.manual(ip: ip))
            dismiss()
        }
    }

    /// Tries each port/path combination and returns a parsed device on the first success.
    private func probeDevice(ip: String) async -> UPnPDevice? {
        for port in probePorts {
            for path in probePaths {
                guard let url = URL(string: "http://\(ip):\(port)\(path)") else { continue }
                var request = URLRequest(url: url, timeoutInterval: 3)
                request.httpMethod = "GET"
                guard let (data, response) = try? await URLSession.shared.data(for: request),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let usn = "manual:\(ip)"
                let location = "http://\(ip):\(port)\(path)"
                let parser = DeviceDescriptionParser(usn: usn, location: location)
                parser.parse(data: data)
                if let device = parser.device {
                    return device
                }
            }
        }
        return nil
    }
}

// MARK: - DeviceRow

private struct DeviceRow: View {
    let device: UPnPDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "tv.fill")
                .font(.title2)
                .foregroundStyle(isSelected ? .blue : .secondary)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(device.friendlyName)
                    .font(.headline)
                Text(device.location)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if device.avTransportControlURL == nil {
                    Text("No AVTransport — may not support casting")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.blue)
            }
        }
        .padding(.vertical, 6)
    }
}
