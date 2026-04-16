import SwiftUI

// MARK: - CastBar (mini player strip above tab bar)

struct CastBar: View {
    @ObservedObject var dlna: DLNAController
    let title: String
    let onTap: () -> Void

    private var isPlaying: Bool { dlna.transportState == .playing }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv.fill")
                .font(.system(size: 13))
                .foregroundColor(Color(hex: "#07070F"))

            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "#07070F"))
                .lineLimit(1)

            Spacer()

            // Play / Pause
            Button {
                Task {
                    if isPlaying { try? await dlna.pause() }
                    else         { try? await dlna.play()  }
                }
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundColor(Color(hex: "#07070F"))
            }

            // Stop
            Button {
                Task { try? await dlna.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13))
                    .foregroundColor(Color(hex: "#07070F").opacity(0.7))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Theme.castActive)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
        .shadow(color: Theme.castActive.opacity(0.35), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

// MARK: - CastControlSheet (full playback controls)

struct CastControlSheet: View {
    @ObservedObject var dlna: DLNAController
    let title: String
    @Binding var isPresented: Bool

    @State private var isSeeking = false
    @State private var seekPosition: Double = 0

    private var isPlaying: Bool { dlna.transportState == .playing }

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Device / state card
                        stateCard

                        // Seek bar (only when content has duration)
                        if dlna.duration > 1 { seekBar }

                        // Transport controls
                        transportControls

                        // Volume
                        volumeControl

                        // Debug
                        Text("transportState: \(dlna.transportState.rawValue)")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding()
                }
            }
            .navigationTitle(title.isEmpty ? "Now Playing" : title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { isPresented = false }
                        .foregroundColor(Theme.accent)
                }
            }
        }
    }

    // MARK: State card

    private var stateCard: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Theme.castActiveBg)
                    .frame(width: 56, height: 56)
                Image(systemName: "tv.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.castActive)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title.isEmpty ? "Воспроизведение" : title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(dlna.transportState.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(stateColor)
            }
            Spacer()
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.bgSecondary)
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.5))
        )
    }

    private var stateColor: Color {
        switch dlna.transportState {
        case .playing:       return Theme.castActive
        case .paused:        return Color(hex: "#FF9F00")
        case .transitioning: return Theme.accent
        default:             return Theme.danger
        }
    }

    // MARK: Seek bar

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

    // MARK: Transport controls

    private var transportControls: some View {
        HStack(spacing: 44) {
            // Stop
            Button {
                Task { try? await dlna.stop() }
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)

            // Rewind 10s
            Button {
                let t = max(0, dlna.currentPosition - 10)
                Task { try? await dlna.seek(to: t) }
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)

            // Play / Pause
            Button {
                Task {
                    if isPlaying { try? await dlna.pause() }
                    else         { try? await dlna.play()  }
                }
            } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 48, height: 48)
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)

            // Forward 30s
            Button {
                let t = dlna.duration > 0
                    ? min(dlna.currentPosition + 30, dlna.duration)
                    : dlna.currentPosition + 30
                Task { try? await dlna.seek(to: t) }
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textMuted)
            }
            .buttonStyle(.plain)

            Color.clear.frame(width: 22, height: 22)
        }
    }

    // MARK: Volume control

    private var volumeControl: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill")
                .foregroundStyle(Theme.textMuted)
                .frame(width: 22)

            Slider(
                value: Binding(
                    get: { Double(dlna.volume) },
                    set: { v in Task { try? await dlna.setVolume(Int(v)) } }
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
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Theme.borderSubtle, lineWidth: 0.5))
        )
    }

    // MARK: Helpers

    private func formatTime(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }
}
