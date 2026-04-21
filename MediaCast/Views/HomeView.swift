import SwiftUI

struct HomeView: View {
    @ObservedObject var httpServer: HTTPServer
    @ObservedObject var dlna: DLNAController
    let selectedDevice: UPnPDevice?
    @Binding var castingTitle: String

    @ObservedObject private var history = HistoryStore.shared

    @State private var searchQuery = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?
    @State private var selectedResult: SearchResult?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationView {
            ZStack {
                Theme.bgPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 12)

                    Divider().background(Theme.borderSubtle)

                    if searchQuery.isEmpty {
                        homeContent
                    } else {
                        searchContent
                    }
                }
            }
            .navigationTitle("RezkaTV")
            .navigationBarTitleDisplayMode(.large)
            .toolbarBackground(Theme.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .sheet(item: $selectedResult) { result in
            InfoSheet(
                result: result,
                httpServer: httpServer,
                dlna: dlna,
                selectedDevice: selectedDevice,
                castingTitle: $castingTitle
            )
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(searchFocused ? Theme.accent : Theme.textMuted)
            TextField("Фильм или сериал…", text: $searchQuery)
                .focused($searchFocused)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .foregroundColor(Theme.textPrimary)
                .onSubmit { Task { await runSearch() } }
            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    results = []
                    searchError = nil
                    searchFocused = false
                } label: {
                    ZStack {
                        Circle().fill(Theme.borderMid).frame(width: 18, height: 18)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13)
                .fill(Theme.bgTertiary)
                .overlay(
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(searchFocused ? Theme.accent : Theme.borderSubtle,
                                      lineWidth: searchFocused ? 1.5 : 0.5)
                )
        )
    }

    // MARK: - Home content

    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                historySection
            }
            .padding(.vertical, 16)
        }
        .background(Theme.bgPrimary)
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("История")
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundColor(Theme.textMuted)
                .padding(.horizontal, 16)

            if history.entries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock")
                        .font(.system(size: 40))
                        .foregroundColor(Theme.textMuted)
                    Text("Нет истории\nЗдесь появятся недавно просмотренные.")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(history.entries.prefix(20))) { entry in
                        historyRow(entry: entry)
                            .padding(.horizontal, 16)
                        if entry.key != history.entries.prefix(20).last?.key {
                            Divider().background(Theme.borderSubtle).padding(.leading, 66)
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
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private func historyRow(entry: HistoryEntry) -> some View {
        Button {
            guard !entry.isLocal else { return }
            selectedResult = SearchResult(url: entry.key, title: entry.title,
                                          poster: entry.poster, info: nil)
        } label: {
            HStack(spacing: 12) {
                // Poster / icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(entry.isLocal ? Theme.bgTertiary : posterColor(for: entry.title))
                        .frame(width: 40, height: 56)
                    if entry.isLocal {
                        Image(systemName: "film")
                            .font(.system(size: 18))
                            .foregroundColor(Theme.textMuted)
                    } else {
                        Text(String(entry.title.prefix(1)).uppercased())
                            .font(.system(size: 16, weight: .heavy))
                            .foregroundColor(Theme.textPrimary.opacity(0.13))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textPrimary)
                        .lineLimit(1)
                    Text(relativeTime(entry.viewedAt))
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }

                Spacer()

                if !entry.isLocal {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textMuted)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(entry.isLocal)
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchContent: some View {
        if isSearching && results.isEmpty {
            ProgressView().tint(Theme.accent).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = searchError {
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40)).foregroundColor(Theme.textMuted)
                Text(err).font(.system(size: 13)).foregroundColor(Theme.textMuted)
                    .multilineTextAlignment(.center)
                Button("Повторить") { Task { await runSearch() } }
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.accent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else if results.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40)).foregroundColor(Theme.textMuted)
                Text("Ничего не найдено").font(.system(size: 13)).foregroundColor(Theme.textMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
        } else {
            List(results) { result in
                ResultRow(result: result)
                    .listRowBackground(Theme.bgPrimary)
                    .listRowSeparatorTint(Theme.borderSubtle)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedResult = result }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Theme.bgPrimary)
        }
    }

    // MARK: - Networking

    private func runSearch() async {
        let q = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        isSearching = true
        searchError = nil
        do {
            let response = try await APIClient.shared.search(q: q)
            results = response.results
            if results.isEmpty { searchError = "Ничего не найдено." }
        } catch {
            searchError = error.localizedDescription
        }
        isSearching = false
    }

    // MARK: - Helpers

    private func relativeTime(_ date: Date) -> String {
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return "только что" }
        if seconds < 3600 { return "\(seconds / 60) мин назад" }
        if seconds < 86400 { return "\(seconds / 3600) ч назад" }
        return "\(seconds / 86400) д назад"
    }
}
