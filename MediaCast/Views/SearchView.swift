import SwiftUI

// MARK: - SearchView

struct SearchView: View {
    @ObservedObject var httpServer: HTTPServer

    /// Set by this view when the user resolves a stream and taps Cast.
    /// PlayerControlView observes this to start casting.
    @Binding var pendingCastURL: URL?
    @Binding var pendingCastTitle: String?

    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?

    @State private var selectedResult: SearchResult?
    @State private var showInfo = false

    var body: some View {
        NavigationView {
            Group {
                if results.isEmpty && !isSearching && searchError == nil {
                    ContentUnavailableView {
                        Label("Search Rezka", systemImage: "magnifyingglass")
                    } description: {
                        Text("Find movies and series to cast to your TV.")
                    }
                } else if let err = searchError {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(err)
                    } actions: {
                        Button("Retry") { Task { await runSearch() } }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List(results) { result in
                        ResultRow(result: result)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedResult = result
                                showInfo = true
                            }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Search")
            .searchable(text: $query, prompt: "Movie or series title…")
            .onSubmit(of: .search) {
                Task { await runSearch() }
            }
            .overlay {
                if isSearching {
                    ProgressView()
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .sheet(isPresented: $showInfo) {
            if let result = selectedResult {
                InfoSheet(
                    result: result,
                    httpServer: httpServer,
                    pendingCastURL: $pendingCastURL,
                    pendingCastTitle: $pendingCastTitle,
                    isPresented: $showInfo
                )
            }
        }
    }

    private func runSearch() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        do {
            let response = try await APIClient.shared.search(q: q)
            results = response.results
            if results.isEmpty { searchError = "No results found." }
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
    }
}

// MARK: - ResultRow

private struct ResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: result.poster.flatMap { URL(string: $0) }) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                default: Color.secondary.opacity(0.2)
                }
            }
            .frame(width: 56, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(result.title)
                    .font(.headline)
                    .lineLimit(2)
                if let info = result.info {
                    Text(info)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - InfoSheet

private struct InfoSheet: View {
    let result: SearchResult
    @ObservedObject var httpServer: HTTPServer
    @Binding var pendingCastURL: URL?
    @Binding var pendingCastTitle: String?
    @Binding var isPresented: Bool

    @State private var info: InfoResponse?
    @State private var isLoading = true
    @State private var loadError: String?

    // Selection state
    @State private var selectedTranslator: RezkaTranslator?
    @State private var selectedSeason: RezkaSeason?
    @State private var selectedEpisode: RezkaEpisode?
    @State private var selectedQuality: StreamQuality?
    @State private var qualities: [StreamQuality] = []

    // Resolve
    @State private var isResolving = false
    @State private var resolveError: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let err = loadError {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: { Text(err) }
                } else if let info {
                    infoBody(info: info)
                }
            }
            .navigationTitle(info?.title ?? result.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
        .task { await loadInfo() }
    }

    @ViewBuilder
    private func infoBody(info: InfoResponse) -> some View {
        Form {
            // Poster + title header
            Section {
                HStack(spacing: 14) {
                    AsyncImage(url: info.poster.flatMap { URL(string: $0) }) { phase in
                        switch phase {
                        case .success(let img): img.resizable().scaledToFill()
                        default: Color.secondary.opacity(0.2)
                        }
                    }
                    .frame(width: 70, height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 6) {
                        Text(info.title ?? result.title)
                            .font(.headline)
                        Text(info.type == "series" ? "Series" : "Movie")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            // Translator picker
            if let translators = info.translators, translators.count > 1 {
                Section("Dubbing") {
                    Picker("Translator", selection: $selectedTranslator) {
                        ForEach(translators) { t in
                            Text(t.name).tag(Optional(t))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedTranslator) { _, _ in
                        qualities = []
                        selectedQuality = nil
                    }
                }
            }

            // Season / episode (series only)
            if info.type == "series", let seasons = info.seasons, !seasons.isEmpty {
                Section("Season") {
                    Picker("Season", selection: $selectedSeason) {
                        ForEach(seasons) { s in
                            Text(s.name).tag(Optional(s))
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: selectedSeason) { _, _ in
                        selectedEpisode = nil
                        qualities = []
                        selectedQuality = nil
                    }
                }

                if let season = selectedSeason, !season.episodes.isEmpty {
                    Section("Episode") {
                        Picker("Episode", selection: $selectedEpisode) {
                            ForEach(season.episodes) { ep in
                                Text(ep.name).tag(Optional(ep))
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedEpisode) { _, _ in
                            qualities = []
                            selectedQuality = nil
                        }
                    }
                }
            }

            // Quality picker (populated after resolve)
            if !qualities.isEmpty {
                Section("Quality") {
                    Picker("Quality", selection: $selectedQuality) {
                        ForEach(qualities) { q in
                            Text(q.quality).tag(Optional(q))
                        }
                    }
                    .pickerStyle(.menu)
                }
            }

            // Error
            if let err = resolveError {
                Section {
                    Text(err)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            // Action buttons
            Section {
                if qualities.isEmpty {
                    Button {
                        Task { await resolveQualities(info: info) }
                    } label: {
                        if isResolving {
                            HStack {
                                ProgressView()
                                Text("Resolving…")
                            }
                        } else {
                            Label("Get stream links", systemImage: "link.circle")
                        }
                    }
                    .disabled(isResolving || (info.type == "series" && selectedEpisode == nil))
                } else {
                    Button {
                        Task { await castSelected(info: info) }
                    } label: {
                        Label("Send to TV", systemImage: "airplayvideo")
                    }
                    .disabled(selectedQuality == nil)
                }
            }
        }
    }

    // MARK: - Actions

    private func loadInfo() async {
        isLoading = true
        loadError = nil
        do {
            let resp = try await APIClient.shared.info(url: result.url)
            info = resp
            // Pre-select defaults
            selectedTranslator = resp.translators?.first
            selectedSeason = resp.seasons?.first
            selectedEpisode = nil
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func resolveQualities(info: InfoResponse) async {
        isResolving = true
        resolveError = nil
        do {
            let resp = try await APIClient.shared.resolve(
                url: result.url,
                season: selectedSeason?.id,
                episode: selectedEpisode?.id,
                translatorId: selectedTranslator?.id
            )
            qualities = resp.qualities
            selectedQuality = resp.qualities.first

            // Pre-register proxy items for all qualities so switching is instant
            // (Only registering selected one is enough; others registered on demand.)
        } catch {
            resolveError = error.localizedDescription
        }
        isResolving = false
    }

    private func castSelected(info: InfoResponse) async {
        guard let quality = selectedQuality else { return }
        guard let cdnURL = URL(string: quality.streamUrl) else {
            resolveError = "Invalid stream URL."
            return
        }

        // Resolve required headers via another resolve call to get fresh headers
        // (they're included in the last resolve response, so re-use them)
        isResolving = true
        resolveError = nil
        do {
            let resp = try await APIClient.shared.resolve(
                url: result.url,
                season: selectedSeason?.id,
                episode: selectedEpisode?.id,
                translatorId: selectedTranslator?.id
            )

            let pickedQuality = resp.qualities.first(where: { $0.quality == quality.quality })
                             ?? resp.qualities.first
            guard let picked = pickedQuality,
                  let url = URL(string: picked.streamUrl) else {
                resolveError = "Could not find stream URL."
                isResolving = false
                return
            }

            guard let proxyURL = httpServer.addProxy(targetURL: url, headers: resp.headers) else {
                resolveError = "Could not start local proxy (no Wi-Fi?)."
                isResolving = false
                return
            }

            let title = buildTitle(info: info)
            pendingCastURL = proxyURL
            pendingCastTitle = title
            isResolving = false
            isPresented = false
        } catch {
            resolveError = error.localizedDescription
            isResolving = false
        }
    }

    private func buildTitle(info: InfoResponse) -> String {
        var t = info.title ?? result.title
        if let s = selectedSeason, let e = selectedEpisode {
            t += " – \(s.name), \(e.name)"
        }
        return t
    }
}
