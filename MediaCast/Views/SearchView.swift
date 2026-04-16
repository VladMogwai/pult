import AVKit
import SwiftUI

// MARK: - ResultRow

struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                AsyncImage(url: result.poster.flatMap { URL(string: $0) }) { phase in
                    switch phase {
                    case .success(let img): img.resizable().scaledToFill()
                    default: posterPlaceholder
                    }
                }
            }
            .frame(width: 56, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                if let info = result.info {
                    Text(info)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var posterPlaceholder: some View {
        ZStack {
            posterColor(for: result.title)
            Text(String(result.title.prefix(1)).uppercased())
                .font(.system(size: 20, weight: .heavy))
                .foregroundColor(Theme.textPrimary.opacity(0.13))
        }
    }
}

// MARK: - InfoSheet

struct InfoSheet: View {
    let result: SearchResult
    @ObservedObject var httpServer: HTTPServer
    @ObservedObject var dlna: DLNAController
    let selectedDevice: UPnPDevice?
    @Binding var castingTitle: String
    @Binding var isPresented: Bool

    @ObservedObject private var dm = DownloadManager.shared

    @State private var info: InfoResponse?
    @State private var isLoading = true
    @State private var loadError: String?

    // Selection state
    @State private var selectedTranslator: RezkaTranslator?
    @State private var selectedSeason: RezkaSeason?
    @State private var selectedEpisode: RezkaEpisode?
    @State private var selectedQuality: StreamQuality?
    @State private var qualities: [StreamQuality] = []
    @State private var lastHeaders: [String: String] = [:]

    // Action state
    @State private var isResolving = false
    @State private var resolveError: String?
    @State private var isCasting = false

    // Local player
    @State private var playerItem: AVPlayerItem?
    @State private var showPlayer = false
    @State private var avPlayer: AVPlayer?

    // MARK: Derived

    private var heroColor: Color { posterColor(for: result.title) }
    private var contentLetter: String { String(result.title.prefix(1)).uppercased() }

    private var downloadKey: String {
        var k = result.url
        if let s = selectedSeason?.id  { k += "__s\(s)" }
        if let e = selectedEpisode?.id { k += "__e\(e)" }
        return k
    }

    var body: some View {
        ZStack(alignment: .top) {
            Theme.bgPrimary.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    heroArea
                    contentArea
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadInfo() }
        .onChange(of: selectedTranslator) { _, _ in autoResolveIfReady() }
        .onChange(of: selectedEpisode)    { _, ep in if ep != nil { autoResolveIfReady() } }
        .fullScreenCover(isPresented: $showPlayer, onDismiss: { avPlayer?.pause() }) {
            if let player = avPlayer {
                VideoPlayerView(player: player, isPresented: $showPlayer)
            }
        }
    }

    private func autoResolveIfReady() {
        guard let info, !isResolving else { return }
        let isSeries = info.type == "series"
        guard !isSeries || selectedEpisode != nil else { return }
        qualities = []
        selectedQuality = nil
        lastHeaders = [:]
        resolveError = nil
        Task { await resolveQualities(info: info) }
    }

    // MARK: - Hero

    private var heroArea: some View {
        ZStack(alignment: .bottom) {
            Rectangle().fill(heroColor)

            if let posterStr = result.poster, let posterURL = URL(string: posterStr) {
                AsyncImage(url: posterURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill()
                    }
                }
                .clipped()
            }

            Rectangle().fill(Color(hex: "#07070F").opacity(0.62))

            VStack {
                HStack {
                    Button { isPresented = false } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 13, weight: .semibold))
                            Text("Назад")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(Theme.textPrimary)
                        .padding(.vertical, 6)
                        .padding(.leading, 9)
                        .padding(.trailing, 13)
                        .background(Capsule().fill(Color(hex: "#07070F").opacity(0.55)))
                    }
                    Spacer()
                }
                .padding(.top, 13)
                .padding(.leading, 13)
                Spacer()
            }

            HStack(alignment: .bottom, spacing: 11) {
                RoundedRectangle(cornerRadius: 9)
                    .fill(heroColor)
                    .overlay(
                        Text(contentLetter)
                            .font(.system(size: 26, weight: .heavy))
                            .foregroundColor(Theme.textPrimary.opacity(0.13))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .frame(width: 70, height: 98)

                VStack(alignment: .leading, spacing: 4) {
                    if let info {
                        let seriesType = info.type == "series"
                        Text(seriesType ? "Сериал" : "Фильм")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.7)
                            .textCase(.uppercase)
                            .foregroundColor(seriesType ? Theme.accent : Theme.castActive)
                            .padding(.vertical, 2)
                            .padding(.horizontal, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(seriesType ? Theme.accentBg : Theme.castActiveBg)
                            )
                    }

                    Text(info?.title ?? result.title)
                        .font(.system(size: 18, weight: .bold))
                        .tracking(-0.3)
                        .foregroundColor(Theme.textPrimary)
                        .shadow(color: Color(hex: "#07070F").opacity(0.9), radius: 3, y: 1)
                        .lineLimit(2)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(height: 195)
        .clipped()
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if isLoading {
            ProgressView()
                .tint(Theme.accent)
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
        } else if let err = loadError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.textMuted)
                Text(err)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        } else if let info {
            infoContent(info: info)
        }
    }

    @ViewBuilder
    private func infoContent(info: InfoResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {

            // Translator chips
            if let translators = info.translators, translators.count > 1 {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Озвучка")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(translators) { t in
                                Button {
                                    if selectedTranslator?.id != t.id {
                                        selectedTranslator = t
                                    }
                                } label: {
                                    ChipView(label: t.name, isActive: t.id == selectedTranslator?.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }
            }

            // Season + episode chips (series only)
            if info.type == "series", let seasons = info.seasons, !seasons.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Сезон")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 5) {
                            ForEach(seasons) { s in
                                Button {
                                    if selectedSeason?.id != s.id {
                                        selectedSeason = s
                                        selectedEpisode = nil
                                        qualities = []
                                        selectedQuality = nil
                                        lastHeaders = [:]
                                        resolveError = nil
                                    }
                                } label: {
                                    ChipView(label: s.name, isActive: s.id == selectedSeason?.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 1)
                    }
                }

                if let season = selectedSeason, !season.episodes.isEmpty {
                    VStack(alignment: .leading, spacing: 7) {
                        sectionLabel("Серия")
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 44), spacing: 5)],
                            spacing: 5
                        ) {
                            ForEach(season.episodes) { ep in
                                Button {
                                    if selectedEpisode?.id != ep.id {
                                        selectedEpisode = ep
                                    }
                                } label: {
                                    ChipView(label: ep.id, isActive: ep.id == selectedEpisode?.id)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            // Quality chips (shown after resolve)
            if !qualities.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    sectionLabel("Качество")
                    HStack(spacing: 5) {
                        ForEach(qualities) { q in
                            Button {
                                selectedQuality = q
                            } label: {
                                ChipView(label: q.quality, isActive: q.id == selectedQuality?.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            if let err = resolveError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.danger)
            }

            actionButtons(info: info)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 20)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.0)
            .textCase(.uppercase)
            .foregroundColor(Theme.textMuted)
    }

    // MARK: - Action buttons

    @ViewBuilder
    private func actionButtons(info: InfoResponse) -> some View {
        let isSeries = info.type == "series"
        let needsEpisode = isSeries && selectedEpisode == nil
        let key = downloadKey
        let downloaded = dm.isDownloaded(key: key)
        let downloading = dm.isDownloading(key: key)

        VStack(spacing: 8) {
            if downloaded {
                // Cast to TV
                Button {
                    Task { await castDownloaded(info: info) }
                } label: {
                    HStack(spacing: 9) {
                        if isCasting {
                            ProgressView().tint(.white).scaleEffect(0.85)
                        } else {
                            Image(systemName: "tv.fill")
                                .font(.system(size: 15))
                        }
                        Text(isCasting ? "Подключение…" : "Транслировать на TV")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isCasting ? Theme.accentDim : Theme.castActive)
                    )
                }
                .disabled(isCasting)

                // Watch on phone (local file)
                Button {
                    if let localURL = dm.localURL(for: key) {
                        let player = AVPlayer(url: localURL)
                        avPlayer = player
                        showPlayer = true
                        player.play()
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "iphone")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                        Text("Смотреть на телефоне")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.bgTertiary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.borderMid, lineWidth: 0.5)
                            )
                    )
                }

                // Delete download
                Button {
                    dm.remove(key: key)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "trash")
                            .font(.system(size: 14))
                            .foregroundColor(Theme.danger)
                        Text("Удалить загрузку")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.danger)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.bgTertiary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.danger.opacity(0.3), lineWidth: 0.5)
                            )
                    )
                }

            } else if downloading {
                let pct = dm.progress[key]
                let mb  = dm.bytesLoaded[key].map { Double($0) / 1_048_576 }
                HStack(spacing: 9) {
                    if let pct, pct > 0 {
                        ProgressView(value: pct)
                            .tint(Theme.accent)
                            .frame(width: 36)
                    } else {
                        ProgressView().tint(Theme.accent).scaleEffect(0.85)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        if let pct, pct > 0 {
                            Text("Скачивается… \(Int(pct * 100))%")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.textMuted)
                        } else {
                            Text("Скачивается…")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(Theme.textMuted)
                        }
                        if let mb, mb > 0 {
                            Text(String(format: "%.1f MB", mb))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textMuted.opacity(0.6))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.bgTertiary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.borderMid, lineWidth: 0.5)
                        )
                )

            } else if isResolving {
                HStack(spacing: 9) {
                    ProgressView().tint(Theme.accent).scaleEffect(0.85)
                    Text("Загрузка…")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.bgTertiary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.borderMid, lineWidth: 0.5)
                        )
                )

            } else if needsEpisode {
                HStack(spacing: 9) {
                    Image(systemName: "hand.tap")
                        .font(.system(size: 15))
                        .foregroundColor(Theme.textMuted)
                    Text("Выберите серию")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.textMuted)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Theme.bgTertiary)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .strokeBorder(Theme.borderMid, lineWidth: 0.5)
                        )
                )

            } else if qualities.isEmpty && resolveError != nil {
                Button {
                    resolveError = nil
                    autoResolveIfReady()
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 15))
                        Text("Попробовать снова")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.accent))
                }

            } else if !qualities.isEmpty {
                // Show download error if any
                if let dmErr = dm.errors[key] {
                    Text(dmErr)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.danger)
                        .padding(.bottom, 4)
                }

                // Download — MP4 direct if directUrl is present, otherwise manual HLS segment download
                Button {
                    guard let quality = selectedQuality else { return }
                    dm.startDownload(
                        key: key,
                        title: buildTitle(info: info),
                        quality: quality,
                        headers: lastHeaders
                    )
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.system(size: 15))
                        Text("Скачать\(selectedQuality != nil ? " (\(selectedQuality!.quality))" : "")")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(selectedQuality == nil ? Theme.accentDim : Theme.accent)
                    )
                }
                .disabled(selectedQuality == nil)

                // Watch on phone via proxy stream
                Button {
                    Task { await watchOnPhone() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "iphone")
                            .font(.system(size: 15))
                            .foregroundColor(Theme.textSecondary)
                        Text("Смотреть на телефоне")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.textPrimary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.bgTertiary)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .strokeBorder(Theme.borderMid, lineWidth: 0.5)
                            )
                    )
                }
                .disabled(selectedQuality == nil)
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Networking

    private func loadInfo() async {
        isLoading = true
        loadError = nil
        do {
            let resp = try await APIClient.shared.info(url: result.url)
            info = resp
            selectedTranslator = resp.translators?.first
            selectedSeason = resp.seasons?.first
            selectedEpisode = nil
            HistoryStore.shared.record(
                key: result.url,
                title: resp.title ?? result.title,
                poster: resp.poster ?? result.poster,
                isLocal: false
            )
            // Auto-resolve for movies immediately
            if resp.type != "series" {
                isLoading = false
                await resolveQualities(info: resp)
                return
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func resolveQualities(info: InfoResponse, attempt: Int = 0) async {
        isResolving = true
        if attempt == 0 { resolveError = nil }
        do {
            // Resolve directly from Rezka CDN — no backend involved
            let resp = try await RezkaDirectClient.shared.resolve(
                url: result.url,
                season: selectedSeason?.id,
                episode: selectedEpisode?.id,
                translatorId: selectedTranslator?.id
            )
            qualities = resp.qualities
            selectedQuality = resp.qualities.first
            lastHeaders = resp.headers
            isResolving = false
        } catch {
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                await resolveQualities(info: info, attempt: attempt + 1)
            } else {
                resolveError = error.localizedDescription
                isResolving = false
            }
        }
    }

    private func castDownloaded(info: InfoResponse) async {
        guard let localURL = dm.localURL(for: downloadKey) else {
            resolveError = "Файл не найден на устройстве."
            return
        }
        guard selectedDevice != nil else {
            resolveError = "Устройство не выбрано. Перейдите в Настройки."
            return
        }
        guard let serveURL = httpServer.addVideo(at: localURL) else {
            resolveError = "Не удалось запустить локальный сервер (нет Wi-Fi?)."
            return
        }

        isCasting = true
        resolveError = nil
        do {
            try await dlna.setAVTransportURI(videoURL: serveURL)
            try await dlna.play()
            castingTitle = buildTitle(info: info)
            isPresented = false
        } catch {
            resolveError = error.localizedDescription
        }
        isCasting = false
    }

    private func watchOnPhone() async {
        guard let quality = selectedQuality,
              let streamURL = URL(string: quality.streamUrl) else { return }

        // Use proxy if there are custom headers, otherwise direct
        let playURL: URL
        if lastHeaders.isEmpty {
            playURL = streamURL
        } else if let proxyURL = httpServer.addProxy(targetURL: streamURL, headers: lastHeaders) {
            playURL = proxyURL
        } else {
            playURL = streamURL
        }

        let player = AVPlayer(url: playURL)
        avPlayer = player
        showPlayer = true
        player.play()
    }

    private func buildTitle(info: InfoResponse) -> String {
        var t = info.title ?? result.title
        if let s = selectedSeason, let e = selectedEpisode {
            t += " – \(s.name), \(e.name)"
        }
        return t
    }
}

// MARK: - VideoPlayerView

struct VideoPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    @Binding var isPresented: Bool

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(isPresented: $isPresented) }

    final class Coordinator: NSObject {
        @Binding var isPresented: Bool
        init(isPresented: Binding<Bool>) { _isPresented = isPresented }
    }
}

// MARK: - Poster color helper

func posterColor(for title: String) -> Color {
    let palette: [Color] = [
        Color(hex: "#1A0A2E"), Color(hex: "#0A1A2E"), Color(hex: "#0A2E1A"),
        Color(hex: "#2E1A0A"), Color(hex: "#1A2E0A"), Color(hex: "#2E0A1A"),
        Color(hex: "#1A1A0A"), Color(hex: "#0A1A1A"), Color(hex: "#2E0A2E"),
        Color(hex: "#0A2E2E"),
    ]
    let idx = abs(title.hashValue) % palette.count
    return palette[idx]
}
