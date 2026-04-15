import SwiftUI

struct PlayerControlView: View {
    @ObservedObject var dlna: DLNAController
    @ObservedObject var httpServer: HTTPServer

    let selectedVideo: URL?
    let selectedDevice: UPnPDevice?

    @State private var isCasting = false
    @State private var errorMessage: String?
    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    private var isPlaying: Bool { dlna.transportState == .playing }
    private var isReadyToCast: Bool { selectedVideo != nil && selectedDevice != nil }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 28) {
                    statusCard
                    if dlna.duration > 1 { seekBar }
                    transportControls
                    volumeControl
                    if isReadyToCast { castButton }
                    debugText
                }
                .padding()
            }
            .navigationTitle("Remote")
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
        VStack(spacing: 10) {
            // Device row
            HStack {
                Image(systemName: "tv.fill")
                    .foregroundStyle(selectedDevice != nil ? .blue : .secondary)
                Text(selectedDevice?.friendlyName ?? "No device selected")
                    .font(.headline)
                    .foregroundStyle(selectedDevice != nil ? .primary : .secondary)
            }

            // File row
            HStack {
                Image(systemName: "film")
                    .foregroundStyle(selectedVideo != nil ? .blue : .secondary)
                Text(selectedVideo?.lastPathComponent ?? "No file selected")
                    .font(.subheadline)
                    .foregroundStyle(selectedVideo != nil ? .primary : .secondary)
                    .lineLimit(1)
            }

            // State badge
            Text(dlna.transportState.displayName)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(stateColor.opacity(0.15))
                .foregroundStyle(stateColor)
                .clipShape(Capsule())
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    private var stateColor: Color {
        switch dlna.transportState {
        case .playing: return .green
        case .paused: return .orange
        case .stopped, .noMediaPresent: return .red
        case .transitioning: return .blue
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
            HStack {
                Text(formatTime(isSeeking ? seekPosition : dlna.currentPosition))
                    .monospacedDigit()
                Spacer()
                Text(formatTime(dlna.duration))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - Transport controls

    private var transportControls: some View {
        HStack(spacing: 44) {
            // Stop
            IconButton(name: "stop.fill", size: 26) {
                Task {
                    do { try await dlna.stop() }
                    catch { errorMessage = error.localizedDescription }
                }
            }

            // Rewind 10 s
            IconButton(name: "gobackward.10", size: 26) {
                let target = max(0, dlna.currentPosition - 10)
                print(">>> SEEK TAPPED to \(target)s (rewind) — currentVideoURL=\(dlna.currentVideoURL?.absoluteString ?? "nil")")
                Task {
                    do { try await dlna.seek(to: target) }
                    catch { print(">>> SEEK ERROR: \(error)") }
                }
            }

            // Play / Pause (big)
            if isCasting {
                ProgressView().frame(width: 64, height: 64)
            } else {
                IconButton(
                    name: isPlaying ? "pause.circle.fill" : "play.circle.fill",
                    size: 64,
                    tint: .blue
                ) {
                    print(">>> TOGGLE TAPPED, isPaused=\(dlna.isPaused), transportState=\(dlna.transportState), isPlaying=\(isPlaying)")
                    Task {
                        do {
                            if isPlaying {
                                print(">>> PAUSE BUTTON TAPPED")
                                try await dlna.pause()
                            } else {
                                print(">>> PLAY BUTTON TAPPED")
                                try await dlna.play()
                            }
                        } catch {
                            print(">>> PAUSE/PLAY ERROR: \(error)")
                            errorMessage = error.localizedDescription
                        }
                    }
                }
            }

            // Forward 30 s
            IconButton(name: "goforward.30", size: 26) {
                let target = min(dlna.currentPosition + 30, dlna.duration)
                print(">>> SEEK TAPPED to \(target)s (forward) — currentVideoURL=\(dlna.currentVideoURL?.absoluteString ?? "nil")")
                Task {
                    do { try await dlna.seek(to: target) }
                    catch { print(">>> SEEK ERROR: \(error)") }
                }
            }

            // Placeholder to balance layout
            Color.clear.frame(width: 26, height: 26)
        }
    }

    // MARK: - Volume control

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(.secondary)
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

            Image(systemName: "speaker.wave.3.fill")
                .foregroundStyle(.secondary)
                .frame(width: 22)
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(14)
    }

    // MARK: - Debug info

    private var debugText: some View {
        Text("transportState: \(dlna.transportState.rawValue)  |  isPaused: \(dlna.isPaused ? "true" : "false")")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }

    // MARK: - Cast button

    private var castButton: some View {
        Button {
            Task { await startCasting() }
        } label: {
            Label("Cast to TV", systemImage: "airplayvideo")
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.blue)
                .foregroundStyle(.white)
                .cornerRadius(14)
                .font(.headline)
        }
        .disabled(isCasting)
    }

    // MARK: - Actions

    private func startCasting() async {
        guard let video = selectedVideo, let device = selectedDevice else { return }

        isCasting = true
        defer { isCasting = false }

        do {
            guard let videoURL = httpServer.addVideo(at: video) else {
                errorMessage = "Could not determine your local IP address. Make sure Wi-Fi is on."
                return
            }

            dlna.selectDevice(device)
            try await dlna.setAVTransportURI(videoURL: videoURL)
            try await dlna.play()
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
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: size))
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    }
}
