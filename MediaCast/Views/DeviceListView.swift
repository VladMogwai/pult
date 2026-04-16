import SwiftUI

struct DeviceListView: View {
    @ObservedObject var ssdp: SSDPDiscovery
    @Binding var selectedDevice: UPnPDevice?

    @State private var showingManualEntry = false

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                Group {
                    if ssdp.devices.isEmpty {
                        emptyView
                    } else {
                        List {
                            ForEach(ssdp.devices) { device in
                                DeviceRow(device: device, isSelected: selectedDevice?.id == device.id)
                                    .listRowBackground(Theme.bgSecondary)
                                    .listRowSeparatorTint(Theme.borderSubtle)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedDevice = device }
                            }
                            if ssdp.isScanning {
                                scanFooter
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                            }
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Devices")
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if ssdp.isScanning {
                        ProgressView().tint(Theme.accent)
                    } else {
                        Button { ssdp.clearAndRediscover() } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundColor(Theme.textSecondary)
                        }
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Add manually") { showingManualEntry = true }
                        .foregroundColor(Theme.accent)
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
                    .tint(Theme.accent)
                Text("Scanning network…")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                Text("Listening for UPnP renderers via SSDP multicast")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "tv.slash")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.textMuted)
                Text("No Devices Found\nNo UPnP renderers were found on your network.")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                Button("Scan Again") { ssdp.clearAndRediscover() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Theme.accentBg)
                            .overlay(
                                RoundedRectangle(cornerRadius: 9)
                                    .strokeBorder(Theme.accent, lineWidth: 1)
                            )
                    )
            }
        }
    }

    private var scanFooter: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.8).tint(Theme.accent)
            Text("Scanning for more devices…")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 8)
    }
}

// MARK: - ManualDeviceSheet

struct ManualDeviceSheet: View {
    let onAdd: (UPnPDevice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ipAddress = ""
    @State private var isProbing = false
    @State private var errorMessage: String?

    private let probePorts: [Int] = [55000, 7676, 8080]
    private let probePaths = ["/dmr", "/description.xml"]

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // IP field group
                        VStack(alignment: .leading, spacing: 10) {
                            Text("TV IP Address")
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.4)
                                .textCase(.uppercase)
                                .foregroundColor(Theme.textMuted)
                            TextField("IP address (e.g. 192.168.1.100)", text: $ipAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .font(.system(size: 13, weight: .regular, design: .monospaced))
                                .foregroundColor(Theme.textPrimary)
                            Divider().background(Theme.borderSubtle)
                            Text("Port defaults to 55000 (Samsung). Fallbacks: 7676, 8080.")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textSecondary)
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

                        // Error
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.danger)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 4)
                        }

                        // Connect button
                        Button {
                            Task { await probe() }
                        } label: {
                            HStack(spacing: 9) {
                                if isProbing {
                                    ProgressView().tint(.white).scaleEffect(0.85)
                                } else {
                                    Image(systemName: "link")
                                        .font(.system(size: 15))
                                }
                                Text(isProbing ? "Connecting…" : "Connect")
                                    .font(.system(size: 15, weight: .semibold))
                            }
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 14)
                                    .fill(isProbing ? Theme.accentDim : Theme.accent)
                            )
                        }
                        .disabled(isProbing || ipAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Add Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(Theme.textSecondary)
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
            isProbing = false
            onAdd(.manual(ip: ip))
            dismiss()
        }
    }

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
                if let device = parser.device { return device }
            }
        }
        return nil
    }
}

// MARK: - DeviceRow

struct DeviceRow: View {
    let device: UPnPDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.castActiveBg : Theme.bgTertiary)
                    .frame(width: 36, height: 36)
                Image(systemName: "tv.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(isSelected ? Theme.castActive : Theme.textMuted)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(device.friendlyName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                Text(device.location)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                if device.avTransportControlURL == nil {
                    Text("No AVTransport — may not support casting")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.danger)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Theme.castActive)
            }
        }
        .padding(.vertical, 6)
    }
}
