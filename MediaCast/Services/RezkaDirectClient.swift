import Foundation

// MARK: - RezkaDirectClient
//
// Entry point for resolving Rezka stream URLs directly from CDN (no backend server).
// Delegates to RezkaWebScraper which uses WKWebView — a real Safari browser context
// that passes Rezka's session/bot checks that URLSession fails.

@MainActor
final class RezkaDirectClient {
    static let shared = RezkaDirectClient()
    private init() {}

    func resolve(
        url: String,
        season: String? = nil,
        episode: String? = nil,
        translatorId: String? = nil
    ) async throws -> ResolveResponse {
        try await RezkaWebScraper.shared.resolve(
            pageURL: url,
            season: season,
            episode: episode,
            translatorId: translatorId
        )
    }
}

// MARK: - Errors

enum RezkaError: LocalizedError {
    case badURL
    case noVideoID
    case decodingFailed
    case badJSON
    case httpError(Int)
    case apiError(String)
    case noQualities

    var errorDescription: String? {
        switch self {
        case .badURL:            return "Неверный URL страницы"
        case .noVideoID:         return "Не удалось найти ID видео на странице"
        case .decodingFailed:    return "Ошибка декодирования страницы"
        case .badJSON:           return "Неверный ответ AJAX"
        case .httpError(let c):  return "HTTP \(c)"
        case .apiError(let msg): return msg
        case .noQualities:       return "Нет доступных качеств видео"
        }
    }
}
