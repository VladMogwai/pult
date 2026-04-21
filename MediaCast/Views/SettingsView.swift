import SwiftUI

struct SettingsView: View {
    @ObservedObject var ssdp: SSDPDiscovery
    @Binding var selectedDevice: UPnPDevice?

    @State private var baseURL = APIClient.shared.baseURL
    @State private var apiKey  = APIClient.shared.apiKey
    @State private var saved   = false
    @FocusState private var focusedField: Field?
    @State private var showManualEntry = false
    @State private var showDeleteAllConfirm = false
    @State private var showFolderPicker = false
    @State private var showRezkaLogin = false
    @State private var showRezkaClearConfirm = false

    @ObservedObject private var dm = DownloadManager.shared

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

                        // MARK: Downloads section
                        downloadsSection

                        // MARK: Rezka section
                        rezkaSection

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

    // MARK: - Rezka section

    private var rezkaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rezka")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(Theme.textMuted)

            settingsGroup {
                VStack(spacing: 12) {
                    HStack(spacing: 10) {
                        Image(systemName: "person.circle")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Аккаунт Rezka")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text("Войдите, чтобы получить доступ к потокам")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button {
                            showRezkaLogin = true
                        } label: {
                            Label("Войти", systemImage: "arrow.right.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent))
                        }
                        Button {
                            showRezkaClearConfirm = true
                        } label: {
                            Label("Выйти", systemImage: "arrow.left.circle")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.danger)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgTertiary))
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showRezkaLogin) {
            RezkaLoginSheet()
        }
        .confirmationDialog("Выйти из Rezka?", isPresented: $showRezkaClearConfirm, titleVisibility: .visible) {
            Button("Выйти и очистить сессию", role: .destructive) {
                RezkaCookies.clearAll {}
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сессионные куки Rezka будут удалены. Для воспроизведения нужно будет войти снова.")
        }
    }

    // MARK: - Downloads section

    private var downloadsSection: some View {
        let entries = Array(dm.entries.values)
        let totalBytes = entries.compactMap { e -> Int64? in
            guard let attr = try? FileManager.default.attributesOfItem(atPath: e.localPath) else { return nil }
            return attr[.size] as? Int64
        }.reduce(0, +)
        let totalMB = Double(totalBytes) / 1_048_576

        return VStack(alignment: .leading, spacing: 10) {
            Text("Загрузки")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(Theme.textMuted)

            // Folder row
            settingsGroup {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 16))
                            .foregroundColor(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Папка загрузок")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.textPrimary)
                            Text(dm.downloadDirectoryDisplayPath)
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted)
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        // Open in Files.app
                        Button {
                            UIApplication.shared.open(URL(string: "shareddocuments://")!)
                        } label: {
                            Label("Открыть в Files", systemImage: "arrow.up.forward.app")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accentBg))
                        }
                        // Change folder
                        Button {
                            showFolderPicker = true
                        } label: {
                            Label("Изменить", systemImage: "folder.badge.gear")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(Theme.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgTertiary))
                        }
                        // Reset to default
                        if dm.downloadDirectoryDisplayPath != "На iPhone / MediaCast" {
                            Button {
                                dm.resetDownloadDirectory()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                                    .font(.system(size: 13))
                                    .foregroundColor(Theme.textMuted)
                                    .frame(width: 36)
                                    .padding(.vertical, 8)
                                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bgTertiary))
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                FolderPickerView { url in
                    dm.setDownloadDirectory(url)
                }
            }

            settingsGroup {
                if entries.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textMuted)
                        Text("Нет загруженных файлов")
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textMuted)
                        Spacer()
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(entries.count) файл\(entries.count == 1 ? "" : entries.count < 5 ? "а" : "ов")")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Theme.textPrimary)
                                Text(String(format: "%.1f MB", totalMB))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textMuted)
                            }
                            Spacer()
                            Button {
                                showDeleteAllConfirm = true
                            } label: {
                                Text("Удалить все")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(Theme.danger)
                            }
                        }

                        Divider().background(Theme.borderSubtle).padding(.vertical, 8)

                        ForEach(entries.sorted { $0.savedAt > $1.savedAt }) { entry in
                            let fileExists = FileManager.default.fileExists(atPath: entry.localPath)
                            let sizeBytes = (try? FileManager.default.attributesOfItem(atPath: entry.localPath))?[.size] as? Int64
                            let sizeMB = sizeBytes.map { String(format: "%.0f MB", Double($0) / 1_048_576) } ?? "?"

                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(fileExists ? Theme.textPrimary : Theme.textMuted)
                                        .lineLimit(2)
                                    HStack(spacing: 6) {
                                        Text(entry.quality)
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(Theme.accent)
                                            .padding(.vertical, 1).padding(.horizontal, 5)
                                            .background(RoundedRectangle(cornerRadius: 3).fill(Theme.accentBg))
                                        Text(fileExists ? sizeMB : "файл удалён")
                                            .font(.system(size: 10))
                                            .foregroundColor(fileExists ? Theme.textMuted : Theme.danger)
                                    }
                                }
                                Spacer()
                                ShareLink(item: URL(fileURLWithPath: entry.localPath)) {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.accent)
                                        .frame(width: 32, height: 32)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accentBg))
                                }
                                DocumentRevealButton(fileURL: URL(fileURLWithPath: entry.localPath))
                                    .frame(width: 32, height: 32)
                                Button {
                                    dm.remove(key: entry.key)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 13))
                                        .foregroundColor(Theme.danger)
                                        .frame(width: 32, height: 32)
                                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.bgTertiary))
                                }
                            }
                            .padding(.vertical, 6)

                            if entry.id != entries.sorted(by: { $0.savedAt > $1.savedAt }).last?.id {
                                Divider().background(Theme.borderSubtle)
                            }
                        }
                    }
                }
            }
        }
        .confirmationDialog("Удалить все загрузки?", isPresented: $showDeleteAllConfirm, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                for key in dm.entries.keys { dm.remove(key: key) }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Все скачанные файлы будут удалены с устройства.")
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
