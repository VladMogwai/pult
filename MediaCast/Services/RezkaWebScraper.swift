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

    // Stream resolve state
    private var continuation: CheckedContinuation<ResolveResponse, Error>?
    private var pendingParams: (season: String?, episode: String?, translatorId: String?)?
    private var resolveTimeout: Task<Void, Never>?

    // Episodes fetch state
    private var episodesContinuation: CheckedContinuation<[RezkaSeason], Error>?
    private var pendingEpisodesTranslatorId: String?
    private var hasPendingEpisodes = false
    private var episodesTimeout: Task<Void, Never>?

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

            print("[RezkaWebScraper] resolve called url=\(pageURL) loadedPageURL=\(self.loadedPageURL ?? "nil") pageIsLoading=\(self.pageIsLoading)")
            print("[MC-DIAG] RezkaWebScraper.resolve url=\(pageURL) season=\(season ?? "nil") episode=\(episode ?? "nil") translatorId=\(translatorId ?? "nil")")

            // If the same content page is already loaded — skip reload and inject AJAX directly.
            // This prevents Rezka from rate-limiting rapid episode switches.
            if self.loadedPageURL == pageURL && !self.pageIsLoading {
                print("[RezkaWebScraper] skipping reload, injecting AJAX directly")
                self.injectAJAXScript()
                return
            }

            self.loadedPageURL = pageURL
            self.pageIsLoading = true
            print("[RezkaWebScraper] loading page in WKWebView")
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            req.setValue(self.ua, forHTTPHeaderField: "User-Agent")
            req.setValue("ru-RU,ru;q=0.9", forHTTPHeaderField: "Accept-Language")
            self.webView.stopLoading()
            self.webView.load(req)
        }
    }

    // MARK: - Public: episode listing

    func getEpisodes(pageURL: String, translatorId: String?) async throws -> [RezkaSeason] {
        return try await withCheckedThrowingContinuation { [weak self] cont in
            guard let self else { cont.resume(throwing: RezkaError.badURL); return }

            self.episodesContinuation = cont
            self.pendingEpisodesTranslatorId = translatorId
            self.hasPendingEpisodes = true

            self.episodesTimeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                await MainActor.run {
                    self?.finishEpisodes(throwing: RezkaError.apiError("Таймаут загрузки эпизодов"))
                }
            }

            guard URL(string: pageURL) != nil else {
                self.finishEpisodes(throwing: RezkaError.badURL)
                return
            }

            if self.loadedPageURL == pageURL && !self.pageIsLoading {
                self.injectGetEpisodesScript()
                return
            }

            // Page needs to load — load it; didFinish will inject the script
            self.loadedPageURL = pageURL
            self.pageIsLoading = true
            var req = URLRequest(url: URL(string: pageURL)!, cachePolicy: .reloadIgnoringLocalCacheData)
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
        ucc.add(WeakMessageHandler(target: self), name: "rezkaEpisodes")
        ucc.add(WeakMessageHandler(target: self), name: "rezkaEpisodesError")
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

        // Capture favs before Rezka's JS removes the input from DOM.
        // The value is present in the raw HTML for anonymous users but gets
        // deleted by page-level scripts shortly after DOMContentLoaded.
        let favsCapture = WKUserScript(
            source: """
            (function() {
                var el = document.querySelector('input[name="favs"]');
                if (el && el.value) { window.__rezkaFavs = el.value; }
            })();
            """,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        ucc.addUserScript(favsCapture)
        webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = self
    }

    private func injectAJAXScript() {
        print("[RezkaWebScraper] injectAJAXScript pendingParams=\(pendingParams != nil)")
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
              window.webkit.messageHandlers.rezkaError.postMessage('[MC-DIAG] no videoId in DOM');
              return;
            }

            var favs = window.__rezkaFavs || '';
            var favsSource = window.__rezkaFavs ? 'captured_early' : 'not_found';
            if (!favs) {
              var favsEl = document.querySelector('input[name="favs"]');
              if (favsEl && favsEl.value) { favs = favsEl.value; favsSource = 'dom_input'; }
            }
            if (!favs) {
              var scripts = document.querySelectorAll('script');
              for (var si = 0; si < scripts.length; si++) {
                var m = scripts[si].textContent.match(/"favs"\\s*:\\s*"([^"]+)"/);
                if (!m) m = scripts[si].textContent.match(/\\bfavs\\s*[=:]\\s*['"]([A-Za-z0-9_\\-]+)['"]/);
                if (m && m[1]) { favs = m[1]; favsSource = 'script_tag[' + si + ']'; break; }
              }
            }

            var allTransEls = Array.prototype.slice.call(document.querySelectorAll('[data-translator_id]'));
            var allTrans = allTransEls.map(function(el) {
              return el.getAttribute('data-translator_id') + ':' + (el.getAttribute('data-translator_name') || el.textContent.trim()).substring(0,20);
            }).join(' | ');

            window.webkit.messageHandlers.rezkaError.postMessage('__debug__ url=' + location.href + ' videoId=' + videoId + ' favs=' + (favs ? favs.substring(0,8)+'...' : 'EMPTY'));
            window.webkit.messageHandlers.rezkaError.postMessage('__diag__ favsSource=' + favsSource + ' allTranslators=[' + allTrans + ']');

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

            var xhrPayload = p.toString();
            window.webkit.messageHandlers.rezkaError.postMessage('__diag__ xhr_payload=' + xhrPayload);

            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/ajax/get_cdn_series/', true);
            xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            xhr.onload = function() {
              window.webkit.messageHandlers.rezkaError.postMessage('__diag__ xhr_status=' + xhr.status + ' raw_response=' + xhr.responseText.substring(0, 500));
              window.webkit.messageHandlers.rezkaResult.postMessage(xhr.responseText);
            };
            xhr.onerror = function() {
              window.webkit.messageHandlers.rezkaError.postMessage('[MC-DIAG] xhr_error status=' + xhr.status);
            };
            xhr.send(xhrPayload);
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

    private func injectGetEpisodesScript() {
        guard hasPendingEpisodes else { return }
        let translatorJS = pendingEpisodesTranslatorId.map { "'\($0)'" } ?? "null"
        let js = """
        (function() {
          try {
            var idEl = document.querySelector('[data-id]');
            var videoId = idEl ? idEl.getAttribute('data-id') : null;
            if (!videoId) {
              var m = document.body.innerHTML.match(/data-id="(\\d+)"/);
              videoId = m ? m[1] : null;
            }
            if (!videoId) {
              window.webkit.messageHandlers.rezkaEpisodesError.postMessage('no videoId');
              return;
            }
            var transEl = document.querySelector('[data-translator_id]');
            var defaultTransId = transEl ? transEl.getAttribute('data-translator_id') : '111';
            var transId = \(translatorJS) || defaultTransId;
            var favs = window.__rezkaFavs || '';
            var p = new URLSearchParams({id: videoId, translator_id: transId, favs: favs, action: 'get_episodes'});
            var xhr = new XMLHttpRequest();
            xhr.open('POST', '/ajax/get_cdn_series/', true);
            xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
            xhr.setRequestHeader('X-Requested-With', 'XMLHttpRequest');
            xhr.onload = function() {
              try {
                var resp = JSON.parse(xhr.responseText);
                if (!resp.success) {
                  window.webkit.messageHandlers.rezkaEpisodesError.postMessage(resp.message || 'API error');
                  return;
                }
                var tmp = document.createElement('div');
                tmp.innerHTML = resp.seasons || '';
                var seasonEls = Array.prototype.slice.call(tmp.querySelectorAll('[data-tab_id]'));
                var tmp2 = document.createElement('div');
                tmp2.innerHTML = resp.episodes || '';
                var epEls = Array.prototype.slice.call(tmp2.querySelectorAll('[data-episode_id]'));
                var seasons = seasonEls.map(function(s) {
                  var sid = s.getAttribute('data-tab_id');
                  var sname = s.textContent.trim();
                  var eps = epEls
                    .filter(function(e) { return e.getAttribute('data-season_id') === sid; })
                    .map(function(e) {
                      return {id: e.getAttribute('data-episode_id'), name: e.textContent.trim()};
                    });
                  return {id: sid, name: sname, episodes: eps};
                });
                window.webkit.messageHandlers.rezkaEpisodes.postMessage(JSON.stringify(seasons));
              } catch(e) {
                window.webkit.messageHandlers.rezkaEpisodesError.postMessage('parse: ' + e.message);
              }
            };
            xhr.onerror = function() {
              window.webkit.messageHandlers.rezkaEpisodesError.postMessage('xhr error ' + xhr.status);
            };
            xhr.send(p.toString());
          } catch(e) {
            window.webkit.messageHandlers.rezkaEpisodesError.postMessage('JS exception: ' + e.message);
          }
        })();
        """
        webView.evaluateJavaScript(js) { [weak self] _, err in
            if let err {
                self?.finishEpisodes(throwing: RezkaError.apiError("JS eval: \(err.localizedDescription)"))
            }
        }
    }

    private func handleEpisodesResult(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8) else {
            finishEpisodes(throwing: RezkaError.badJSON)
            return
        }
        do {
            let decoder = JSONDecoder()
            let seasons = try decoder.decode([RezkaSeason].self, from: data)
            finishEpisodes(with: seasons)
        } catch {
            finishEpisodes(throwing: RezkaError.badJSON)
        }
    }

    private func finishEpisodes(with seasons: [RezkaSeason]) {
        episodesTimeout?.cancel()
        episodesTimeout = nil
        hasPendingEpisodes = false
        pendingEpisodesTranslatorId = nil
        episodesContinuation?.resume(returning: seasons)
        episodesContinuation = nil
    }

    private func finishEpisodes(throwing error: Error) {
        episodesTimeout?.cancel()
        episodesTimeout = nil
        hasPendingEpisodes = false
        pendingEpisodesTranslatorId = nil
        episodesContinuation?.resume(throwing: error)
        episodesContinuation = nil
    }

    private func handleResult(_ jsonString: String) {
        print("[MC-DIAG] handleResult raw (first 500): \(jsonString.prefix(500))")
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[MC-DIAG] handleResult JSON parse failed")
            finish(throwing: RezkaError.badJSON)
            return
        }

        guard let success = json["success"] as? Bool, success else {
            let msg = (json["message"] as? String) ?? "Rezka API error"
            print("[MC-DIAG] handleResult success=false message=\(msg)")
            // Clear page cache on session error — next retry reloads the page and gets a fresh favs token
            if msg.contains("сессии") || msg.lowercased().contains("session") {
                loadedPageURL = nil
            }
            finish(throwing: RezkaError.apiError(msg))
            return
        }

        let rawURL  = (json["url"] as? String) ?? ""
        print("[MC-DIAG] handleResult rawURL (first 500): \(rawURL.prefix(500))")
        let decoded = clearTrash(rawURL)
        print("[MC-DIAG] handleResult clearTrash (first 500): \(decoded.prefix(500))")
        print(">>> Scraper decoded URL (\(decoded.count) chars): \(decoded)")
        let qualities = parseQualities(decoded)
        print("[MC-DIAG] handleResult qualities: \(qualities.map { "\($0.quality) stream=\($0.streamUrl.prefix(60)) direct=\(($0.directUrl?.prefix(60)).map(String.init) ?? "nil")" })")
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
            let pageURL = webView.url?.absoluteString ?? "nil"
            print("[RezkaWebScraper] didFinish pendingParams=\(self?.pendingParams != nil) url=\(pageURL)")
            webView.evaluateJavaScript("document.readyState") { value, _ in
                print("[MC-DIAG] didFinish ts=\(Date().timeIntervalSince1970) readyState=\(value as? String ?? "?") url=\(pageURL)")
            }
            self?.pageIsLoading = false
            // Brief delay lets page-level JS finish populating the DOM (favs input, etc.)
            try? await Task.sleep(nanoseconds: 500_000_000)
            if self?.pendingParams != nil { self?.injectAJAXScript() }
            if self?.hasPendingEpisodes == true { self?.injectGetEpisodesScript() }
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
            if message.name == "rezkaEpisodes" {
                self.handleEpisodesResult(body)
            } else if message.name == "rezkaEpisodesError" {
                print("[RezkaWebScraper] episodes error: \(body)")
                self.finishEpisodes(throwing: RezkaError.apiError(body))
            } else if message.name == "rezkaError" {
                if body.hasPrefix("__debug__") {
                    print("[RezkaWebScraper] \(body)")
                    return
                }
                if body.hasPrefix("__diag__") {
                    print("[MC-DIAG] JS \(body)")
                    return
                }
                print("[RezkaWebScraper] JS error: \(body)")
                print("[MC-DIAG] RezkaWebScraper error: \(body)")
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
