import WebKit
import Foundation

// MARK: - RezkaWebScraper
//
// Resolves Rezka CDN stream URLs using WKWebView instead of URLSession.
//
// Why WKWebView?
//   URLSession lacks a real browser TLS fingerprint and JavaScript execution context.
//   Rezka's session validation runs server-side and is tied to the browser's cookie/JS
//   environment. WKWebView is Safari WebKit — it passes all bot/session checks that
//   URLSession fails.
//
// Flow:
//   1. WKWebView loads the content page (real browser cookies, JS, TLS fingerprint)
//   2. After didFinish, inject JS that reads data-id/favs/translator_id from the DOM
//   3. Injected JS makes XMLHttpRequest to /ajax/get_cdn_series/ in the same origin context
//   4. Result is posted back via window.webkit.messageHandlers
//   5. Swift parses JSON → clearTrash → [StreamQuality]

@MainActor
final class RezkaWebScraper: NSObject {

    static let shared = RezkaWebScraper()

    private let ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36"

    private var webView: WKWebView!
    private var continuation: CheckedContinuation<ResolveResponse, Error>?
    private var pendingParams: (season: String?, episode: String?, translatorId: String?)?
    private var resolveTimeout: Task<Void, Never>?

    /// URL that is currently loaded (or being loaded) in the WebView.
    /// We skip reloading if the same content page is requested again — this avoids
    /// Rezka rate-limiting AJAX calls caused by rapid page reloads between episodes.
    private var loadedPageURL: String?
    private var pageIsLoading = false

    private override init() {
        super.init()
        setupWebView()
    }

    // MARK: - Public

    func resolve(
        pageURL: String,
        season: String?,
        episode: String?,
        translatorId: String?
    ) async throws -> ResolveResponse {

        // Cancel any in-flight resolution
        finishWithError(RezkaError.apiError("cancelled"))

        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else { cont.resume(throwing: RezkaError.badURL); return }

            self.continuation = cont
            self.pendingParams = (season: season, episode: episode, translatorId: translatorId)

            guard let url = URL(string: pageURL) else {
                self.finish(throwing: RezkaError.badURL)
                return
            }

            // 30-second hard timeout
            self.resolveTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                await MainActor.run {
                    self?.finish(throwing: RezkaError.apiError("Таймаут загрузки страницы"))
                }
            }

            // If the same content page is already loaded — skip reload and inject AJAX directly.
            // This prevents Rezka from rate-limiting rapid episode switches.
            if self.loadedPageURL == pageURL && !self.pageIsLoading {
                self.injectAJAXScript()
                return
            }

            self.loadedPageURL = pageURL
            self.pageIsLoading = true
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.setValue(self.ua, forHTTPHeaderField: "User-Agent")
            req.setValue("ru-RU,ru;q=0.9", forHTTPHeaderField: "Accept-Language")
            self.webView.stopLoading()
            self.webView.load(req)
        }
    }

    // MARK: - Private helpers

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        let ucc = WKUserContentController()
        ucc.add(WeakMessageHandler(target: self), name: "rezkaResult")
        ucc.add(WeakMessageHandler(target: self), name: "rezkaError")
        config.userContentController = ucc
        // Block most resources to speed up loading (we only need the HTML)
        let blockScript = WKUserScript(
            source: """
            var style = document.createElement('style');
            style.textContent = 'img,video,iframe{display:none!important}';
            document.head?.appendChild(style);
            """,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        ucc.addUserScript(blockScript)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
    }

    private func injectAJAXScript() {
        guard let params = pendingParams else { return }

        let seasonJS    = params.season.map    { "'\($0)'" } ?? "null"
        let episodeJS   = params.episode.map   { "'\($0)'" } ?? "null"
        let translatorJS = params.translatorId.map { "'\($0)'" } ?? "null"

        let js = """
        (function() {
          try {
            var id = document.querySelector('[data-id]');
            if (!id) { id = document.body.innerHTML.match(/data-id="(\\d+)"/); }
            var videoId = id instanceof Element
              ? id.getAttribute('data-id')
              : (id ? id[1] : null);
            if (!videoId) {
              window.webkit.messageHandlers.rezkaError.postMessage('No video ID in DOM');
              return;
            }
            var favsEl = document.querySelector('input[name="favs"]');
            var favs = favsEl ? favsEl.value : '';
            var transEl = document.querySelector('[data-translator_id]');
            var transId = \(translatorJS) || (transEl ? transEl.getAttribute('data-translator_id') : '111') || '111';
            var season  = \(seasonJS);
            var episode = \(episodeJS);
            var isSeries = !!(season && episode);
            var p = new URLSearchParams({
              id: videoId, translator_id: transId, favs: favs,
              action: isSeries ? 'get_stream' : 'get_movie'
            });
            if (isSeries) { p.append('season', season); p.append('episode', episode); }
            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/ajax/get_cdn_series/', true);
            xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            xhr.onload = function() {
              window.webkit.messageHandlers.rezkaResult.postMessage(xhr.responseText);
            };
            xhr.onerror = function() {
              window.webkit.messageHandlers.rezkaError.postMessage('XHR error status=' + xhr.status);
            };
            xhr.send(p.toString());
          } catch(e) {
            window.webkit.messageHandlers.rezkaError.postMessage('JS exception: ' + e.message);
          }
        })();
        """

        webView.evaluateJavaScript(js) { [weak self] _, err in
            if let err {
                self?.finish(throwing: RezkaError.apiError("JS eval: \(err.localizedDescription)"))
            }
        }
    }

    private func handleResult(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            finish(throwing: RezkaError.badJSON)
            return
        }

        guard let success = json["success"] as? Bool, success else {
            let msg = (json["message"] as? String) ?? "Rezka API error"
            finish(throwing: RezkaError.apiError(msg))
            return
        }

        let rawURL  = (json["url"] as? String) ?? ""
        let decoded = clearTrash(rawURL)
        print(">>> Scraper decoded URL (\(decoded.count) chars): \(decoded)")
        let qualities = parseQualities(decoded)
        print(">>> Scraper qualities: \(qualities.map { "\($0.quality) direct=\($0.directUrl != nil)" })")

        if qualities.isEmpty {
            finish(throwing: RezkaError.noQualities)
            return
        }

        let origin = webView.url.map { "\($0.scheme ?? "https")://\($0.host ?? "")" } ?? ""
        finish(with: ResolveResponse(
            qualities: qualities,
            headers: ["Referer": origin + "/", "User-Agent": ua]
        ))
    }

    private func finish(with response: ResolveResponse) {
        resolveTimeout?.cancel()
        resolveTimeout = nil
        pendingParams = nil
        continuation?.resume(returning: response)
        continuation = nil
    }

    private func finish(throwing error: Error) {
        resolveTimeout?.cancel()
        resolveTimeout = nil
        pendingParams = nil
        continuation?.resume(throwing: error)
        continuation = nil
    }

    private func finishWithError(_ error: Error) {
        guard continuation != nil else { return }
        finish(throwing: error)
    }

    // MARK: - clearTrash (Swift port of JS clearTrash)

    private func clearTrash(_ data: String) -> String {
        let trashChars: [Character] = ["@", "#", "!", "^", "$"]
        var combos: [String] = []
        for a in trashChars {
            for b in trashChars {
                combos.append(String([a, b]))
                for c in trashChars { combos.append(String([a, b, c])) }
            }
        }
        var s = data
            .replacingOccurrences(of: "#h", with: "")
            .replacingOccurrences(of: "//_//", with: "")
        for combo in combos {
            let encoded = Data(combo.utf8).base64EncodedString()
            s = s.replacingOccurrences(of: encoded, with: "")
        }
        if let decoded = Data(base64Encoded: s, options: .ignoreUnknownCharacters),
           let result  = String(data: decoded, encoding: .utf8),
           !result.isEmpty {
            return result
        }
        return s
    }

    // MARK: - Quality parser

    private func parseQualities(_ urlString: String) -> [StreamQuality] {
        var results: [StreamQuality] = []
        guard let regex = try? NSRegularExpression(pattern: #"\[([^\]]+)\](https?://[^\[]+)"#) else { return [] }
        let ns      = urlString as NSString
        let matches = regex.matches(in: urlString, range: NSRange(location: 0, length: ns.length))

        for m in matches {
            guard m.numberOfRanges >= 3 else { continue }
            let quality = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            let raw = ns.substring(with: m.range(at: 2))
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: ",$", with: "", options: .regularExpression)
            if let orRange = raw.range(of: " or ") {
                results.append(StreamQuality(quality: quality, streamUrl: String(raw[..<orRange.lowerBound]), directUrl: String(raw[orRange.upperBound...])))
            } else {
                results.append(StreamQuality(quality: quality, streamUrl: raw, directUrl: nil))
            }
        }

        let order = ["1080p Ultra", "1080p", "720p", "480p", "360p"]
        results.sort { (order.firstIndex(of: $0.quality) ?? 99) < (order.firstIndex(of: $1.quality) ?? 99) }
        return results
    }
}

// MARK: - WKNavigationDelegate

extension RezkaWebScraper: WKNavigationDelegate {

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in
            self?.pageIsLoading = false
            self?.injectAJAXScript()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.pageIsLoading = false
            self?.loadedPageURL = nil
            self?.finish(throwing: error)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in
            self?.pageIsLoading = false
            self?.loadedPageURL = nil
            self?.finish(throwing: error)
        }
    }
}

// MARK: - WKScriptMessageHandler (weak proxy to avoid retain cycle)

extension RezkaWebScraper: WKScriptMessageHandler {

    nonisolated func userContentController(
        _ ucc: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        // Capture message before hopping to MainActor — body/name access must be on main thread
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let body = message.body as? String else { return }
            if message.name == "rezkaError" {
                print("[RezkaWebScraper] JS error: \(body)")
                self.finish(throwing: RezkaError.apiError(body))
            } else {
                self.handleResult(body)
            }
        }
    }
}

// MARK: - WeakMessageHandler (breaks WKUserContentController retain cycle)

private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (NSObject & WKScriptMessageHandler)?
    init(target: NSObject & WKScriptMessageHandler) { self.target = target }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
