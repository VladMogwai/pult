import Combine
import Foundation

struct HistoryEntry: Codable, Identifiable {
    var id: String { key }
    let key: String        // Rezka page URL or local file absoluteString
    let title: String
    let poster: String?    // nil for local files
    let isLocal: Bool
    var viewedAt: Date
}

// MARK: - HistoryStore

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var entries: [HistoryEntry] = []

    func record(key: String, title: String, poster: String?, isLocal: Bool = false) {
        entries.removeAll { $0.key == key }
        entries.insert(
            HistoryEntry(key: key, title: title, poster: poster,
                         isLocal: isLocal, viewedAt: Date()),
            at: 0
        )
        if entries.count > 50 { entries = Array(entries.prefix(50)) }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: "history_entries_v1")
        }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: "history_entries_v1"),
           let d = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = d
        }
    }
}
