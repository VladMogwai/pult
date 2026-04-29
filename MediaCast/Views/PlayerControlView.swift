import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var dlna: DLNAController
    @ObservedObject var httpServer: HTTPServer

    let selectedVideo: URL?
    let selectedDevice: UPnPDevice?

    /// Set by SearchView when it resolves a stream. Cleared after cast starts.
    @Binding var pendingCastURL: URL?
    @Binding var pendingCastTitle: String?

    @State private var isCasting = false
    @State private var errorMessage: String?
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    private var isPlaying: Bool { dlna.transportState == .playing }
    private var isReadyToCast: Bool {
        selectedDevice != nil && (selectedVideo != nil || pendingCastURL != nil)
    }
    private var currentTitle: String {
        pendingCastTitle ?? selectedVideo?.lastPathComponent ?? "No content selected"
    }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        statusCard
                        if dlna.duration > 1 { seekBar }
                        transportControls
                        volumeControl
                        if isReadyToCast { castButton }
                        debugText
                    }
                    .padding()
                }
            }
            .navigationTitle("Remote")
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .alert("Playback Error", isPresented: .init(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Status card

    private var statusCard: some View {
        VStack(spacing: 12) {
            // Device row
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(selectedDevice != nil ? Theme.castActiveBg : Theme.bgTertiary)
                        .frame(width: 56, height: 56)
                    Image(systemName: "tv.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(selectedDevice != nil ? Theme.castActive : Theme.textMuted)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedDevice?.friendlyName ?? "No device selected")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(selectedDevice != nil ? Theme.textPrimary : Theme.textSecondary)
                    Text("Подключено · DLNA/UPnP")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textMuted)
                }
                Spacer()
            }

            Divider().background(Theme.borderSubtle)

            // Content row
            HStack(spacing: 10) {
                Image(systemName: pendingCastURL != nil ? "magnifyingglass.circle.fill" : "film")
                    .font(.system(size: 16))
                    .foregroundStyle((selectedVideo != nil || pendingCastURL != nil) ? Theme.accent : Theme.textMuted)
                Text(currentTitle)
                    .font(.system(size: 13))
                    .foregroundStyle((selectedVideo != nil || pendingCastURL != nil) ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }

            // State badge
            Text(dlna.transportState.displayName)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(stateColor.opacity(0.15))
                .foregroundStyle(stateColor)
                .clipShape(Capsule())
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.bgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private var stateColor: Color {
        switch dlna.transportState {
        case .playing:        return Theme.castActive
        case .paused:         return Color(hex: "#FF9F00")
        case .transitioning:  return Theme.accent
        case .stopped, .noMediaPresent: return Theme.danger
        }
    }

    // MARK: - Seek bar

    private var seekBar: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { isSeeking ? seekPosition : dlna.currentPosition },
                    set: { seekPosition = $0 }
                ),
                in: 0...max(dlna.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        isSeeking = true
                        seekPosition = dlna.currentPosition
                    } else {
                        isSeeking = false
                        let target = seekPosition
                        print(">>> SEEK TAPPED to \(target)s (slider) — currentVideoURL=\(dlna.currentVideoURL?.absoluteString ?? "nil")")
                        Task {
                            do { try await dlna.seek(to: target) }
                            catch { print(">>> SEEK ERROR: \(error)") }
                        }
                    }
                }
            )
            .tint(Theme.accent)

            HStack {
                Text(formatTime(isSeeking ? seekPosition : dlna.currentPosition))
                    .monospacedDigit()
                Spacer()
                Text(formatTime(dlna.duration))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        VStack(spacing: 16) {
            // ←30s  ←10s  ▶/⏸  +10s  +30s
            HStack(spacing: 28) {
                IconButton(name: "gobackward.30", size: 22, tint: Theme.textMuted) {
                    let t = max(0, dlna.currentPosition - 30)
                    print(">>> SKIP -30s → \(t)s")
                    Task {
                        do { try await dlna.seek(to: t) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }

                IconButton(name: "gobackward.10", size: 22, tint: Theme.textMuted) {
                    let t = max(0, dlna.currentPosition - 10)
                    print(">>> SKIP -10s → \(t)s")
                    Task {
                        do { try await dlna.seek(to: t) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }

                // Play / Pause
                if isCasting {
                    ProgressView()
                        .tint(Theme.accent)
                        .frame(width: 56, height: 56)
                } else {
                    Button {
                        Task {
                            do {
                                if isPlaying { try await dlna.pause() }
                                else         { try await dlna.play()  }
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 56, height: 56)
                            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }

                IconButton(name: "goforward.10", size: 22, tint: Theme.textMuted) {
                    let t = dlna.duration > 0
                        ? min(dlna.currentPosition + 10, dlna.duration)
                        : dlna.currentPosition + 10
                    print(">>> SKIP +10s → \(t)s")
                    Task {
                        do { try await dlna.seek(to: t) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }

                IconButton(name: "goforward.30", size: 22, tint: Theme.textMuted) {
                    let t = dlna.duration > 0
                        ? min(dlna.currentPosition + 30, dlna.duration)
                        : dlna.currentPosition + 30
                    print(">>> SKIP +30s → \(t)s")
                    Task {
                        do { try await dlna.seek(to: t) }
                        catch { errorMessage = error.localizedDescription }
                    }
                }
            }

            // Stop — отдельная строка, меньше акцента
            IconButton(name: "stop.fill", size: 16, tint: Theme.textMuted) {
                Task {
                    do { try await dlna.stop() }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
    }

    // MARK: - Volume control

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(Theme.textMuted)
                .frame(width: 22)

            Slider(
                value: Binding(
                    get: { Double(dlna.volume) },
                    set: { newVol in
                        Task { try? await dlna.setVolume(Int(newVol)) }
                    }
                ),
                in: 0...100
            )
            .tint(Theme.accent)

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(Theme.textMuted)
                .frame(width: 22)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.bgSecondary)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    // MARK: - Debug info

    private var debugText: some View {
        Text("transportState: \(dlna.transportState.rawValue)  |  isPaused: \(dlna.isPaused ? "true" : "false")")
            .font(.system(size: 11))
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
    }

    // MARK: - Cast button

    private var castButton: some View {
        Button {
            Task { await startCasting() }
        } label: {
            HStack(spacing: 9) {
                if isCasting {
                    ProgressView().tint(.white).scaleEffect(0.85)
                } else {
                    Image(systemName: "airplayvideo")
                        .font(.system(size: 15))
                }
                Text(isCasting ? "Connecting…" : "Cast to TV")
                    .font(.system(size: 15, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isCasting ? Theme.accentDim : Theme.accent)
            )
        }
        .disabled(isCasting)
    }

    // MARK: - Actions

    private func startCasting() async {
        guard let device = selectedDevice else { return }

        isCasting = true
        defer { isCasting = false }

        do {
            let castURL: URL
            if let streamURL = pendingCastURL {
                castURL = streamURL
            } else if let video = selectedVideo {
                guard let localURL = httpServer.addVideo(at: video) else {
                    errorMessage = "Could not determine your local IP address. Make sure Wi-Fi is on."
                    return
                }
                castURL = localURL
            } else {
                return
            }

            dlna.selectDevice(device)
            try await dlna.setAVTransportURI(videoURL: castURL)
            try await dlna.play()

            pendingCastURL = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: TimeInterval) -> String {
        let t = Int(max(0, seconds))
        let h = t / 3600
        let m = (t % 3600) / 60
        let s = t % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

// MARK: - IconButton

private struct IconButton: View {
    let name: String
    var size: CGFloat = 28
    var tint: Color = Theme.textMuted
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)   // минимальная tap-зона по HIG
                .contentShape(Rectangle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.78 : 1.0)
            .opacity(configuration.isPressed ? 0.55 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
