import Foundation

// MARK: - Search

struct SearchResult: Identifiable, Decodable {
    let url: String
    let title: String
    let poster: String?
    let info: String?
    var id: String { url }
}

struct SearchResponse: Decodable {
    let domain: String
    let results: [SearchResult]
}

// MARK: - Info

struct RezkaTranslator: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
}

struct RezkaEpisode: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
}

struct RezkaSeason: Identifiable, Decodable, Hashable {
    let id: String
    let name: String
    let episodes: [RezkaEpisode]
}

struct InfoResponse: Decodable {
    let type: String          // "movie" | "series" | "other"
    let title: String?
    let poster: String?
    let translators: [RezkaTranslator]?
    let seasons: [RezkaSeason]?
}

// MARK: - Resolve

struct StreamQuality: Identifiable, Decodable, Hashable {
    let quality: String
    let streamUrl: String
    let directUrl: String?
    var id: String { quality }

    enum CodingKeys: String, CodingKey {
        case quality
        case streamUrl
        case directUrl
    }
}

struct ResolveResponse: Decodable {
    let qualities: [StreamQuality]
    let headers: [String: String]
}
