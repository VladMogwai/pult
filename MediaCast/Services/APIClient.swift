import Foundation

// MARK: - APIClient

final class APIClient {
    static let shared = APIClient()
    private init() {}

    // Set via Settings screen or hardcode your Render URL here.
    var baseURL: String {
        get { UserDefaults.standard.string(forKey: "api_base_url") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "api_base_url") }
    }

    var apiKey: String {
        get { UserDefaults.standard.string(forKey: "api_key") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "api_key") }
    }

    // MARK: - Search

    func search(q: String) async throws -> SearchResponse {
        guard let base = validBase() else { throw APIError.noBaseURL }
        var comps = URLComponents(string: "\(base)/api/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: q)]
        let req = makeRequest(url: comps.url!)
        return try await perform(req)
    }

    // MARK: - Info

    func info(url: String) async throws -> InfoResponse {
        guard let base = validBase() else { throw APIError.noBaseURL }
        var req = makeRequest(url: URL(string: "\(base)/api/info")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["url": url])
        return try await perform(req)
    }

    // MARK: - Resolve

    func resolve(
        url: String,
        season: String? = nil,
        episode: String? = nil,
        translatorId: String? = nil
    ) async throws -> ResolveResponse {
        guard let base = validBase() else { throw APIError.noBaseURL }
        var req = makeRequest(url: URL(string: "\(base)/api/resolve")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = ["url": url]
        if let s = season       { body["season"] = s }
        if let e = episode      { body["episode"] = e }
        if let t = translatorId { body["translatorId"] = t }
        req.httpBody = try JSONEncoder().encode(body)
        return try await perform(req)
    }

    // MARK: - Helpers

    private func validBase() -> String? {
        let b = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? nil : b
    }

    private func makeRequest(url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 15)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        return req
    }

    private func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.httpError(http.statusCode, body)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case noBaseURL
    case invalidResponse
    case httpError(Int, String)

    var errorDescription: String? {
        switch self {
        case .noBaseURL:
            return "API server URL is not configured. Go to Settings tab."
        case .invalidResponse:
            return "Invalid server response."
        case .httpError(let code, let body):
            if let msg = try? JSONDecoder().decode([String: String].self, from: body.data(using: .utf8) ?? Data())["error"] {
                return msg
            }
            return "Server error \(code)."
        }
    }
}
