import SwiftUI

struct SettingsView: View {
    @ObservedObject var ssdp: SSDPDiscovery
    @Binding var selectedDevice: UPnPDevice?

    @State private var baseURL = APIClient.shared.baseURL
    @State private var apiKey  = APIClient.shared.apiKey
    @State private var saved   = false
    @FocusState private var focusedField: Field?
    @State private var showManualEntry = false

    @AppStorage("auto_connect") private var autoConnect = false

    private enum Field { case url, key }

    private var lastDeviceName: String {
        UserDefaults.standard.string(forKey: "last_device_name") ?? ""
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {

                        // MARK: Devices section
                        deviceSection

                        // MARK: API Server URL
                        settingsGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("API Server URL")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.4)
                                    .textCase(.uppercase)
                                    .foregroundColor(Theme.textMuted)
                                TextField("https://your-app.onrender.com", text: $baseURL)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .focused($focusedField, equals: .url)
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                Divider().background(Theme.borderSubtle)
                                Text("Base URL of your video-downloader backend (no trailing slash).")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }

                        // MARK: API Key
                        settingsGroup {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("API Key")
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.4)
                                    .textCase(.uppercase)
                                    .foregroundColor(Theme.textMuted)
                                SecureField("Optional", text: $apiKey)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                                    .focused($focusedField, equals: .key)
                                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                                    .foregroundColor(Theme.textPrimary)
                                Divider().background(Theme.borderSubtle)
                                Text("Bearer token. Leave empty if API_KEY is not set on the server.")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textSecondary)
                            }
                        }

                        // Save button
                        Button {
                            focusedField = nil
                            APIClient.shared.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            APIClient.shared.apiKey  = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                            saved = true
                        } label: {
                            Text("Сохранить")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Theme.accent)
                                )
                        }
                    }
                    .padding(16)
                }
                .simultaneousGesture(
                    TapGesture().onEnded { focusedField = nil }
                )
            }
            .navigationTitle("Настройки")
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Сохранено", isPresented: $saved) {
                Button("OK", role: .cancel) {}
            }
        }
        .sheet(isPresented: $showManualEntry) {
            ManualDeviceSheet { device in
                ssdp.addDevice(device)
                selectedDevice = device
            }
        }
    }

    // MARK: - Device section

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: label + scan/refresh button
            HStack {
                Text("Устройства")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.9)
                    .textCase(.uppercase)
                    .foregroundColor(Theme.textMuted)

                Spacer()

                if ssdp.isScanning {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.75).tint(Theme.accent)
                        Text("Поиск…")
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textMuted)
                    }
                } else {
                    Button {
                        ssdp.clearAndRediscover()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .medium))
                            Text("Обновить")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(Theme.accent)
                    }
                }
            }

            // Device list or empty state
            VStack(spacing: 0) {
                if ssdp.devices.isEmpty && !ssdp.isScanning {
                    HStack(spacing: 10) {
                        Image(systemName: "tv.slash")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textMuted)
                        Text("Устройства не найдены")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                    }
                    .padding(16)
                } else {
                    ForEach(ssdp.devices) { device in
                        let isSelected = selectedDevice?.id == device.id
                        Button {
                            selectedDevice = device
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(isSelected ? Theme.castActiveBg : Theme.bgTertiary)
                                        .frame(width: 32, height: 32)
                                    Image(systemName: "tv.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(isSelected ? Theme.castActive : Theme.textMuted)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.friendlyName)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                    Text(device.location)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.textMuted)
                                        .lineLimit(1)
                                }

                                Spacer()

                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Theme.castActive)
                                        .font(.system(size: 16))
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)

                        if device.id != ssdp.devices.last?.id {
                            Divider().background(Theme.borderSubtle).padding(.leading, 60)
                        }
                    }

                    if ssdp.isScanning && !ssdp.devices.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView().scaleEffect(0.75).tint(Theme.accent)
                            Text("Ищем ещё…")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textMuted)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                    }
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
            )

            // Auto-connect toggle
            settingsGroup {
                VStack(spacing: 0) {
                    Toggle(isOn: $autoConnect) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Автоподключение")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            if !lastDeviceName.isEmpty {
                                Text("Последнее: \(lastDeviceName)")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted)
                            } else {
                                Text("Подключаться к ранее выбранному устройству")
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted)
                            }
                        }
                    }
                    .tint(Theme.accent)
                }
            }

            // Add manually button
            Button {
                showManualEntry = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 14))
                    Text("Добавить вручную")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(Theme.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.bgSecondary)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                    )
            )
    }
}
