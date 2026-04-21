import SwiftUI
import WebKit

// MARK: - RezkaLoginSheet

struct RezkaLoginSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            RezkaWebViewWrapper()
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Войти в Rezka")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Закрыть") { dismiss() }
                            .foregroundColor(Theme.accent)
                    }
                }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - WKWebView wrapper

struct RezkaWebViewWrapper: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Must use .default() to share cookies with RezkaWebScraper's WKWebView,
        // which also uses .default() (the implicit default for WKWebViewConfiguration).
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.load(URLRequest(url: URL(string: "https://rezka-ua.tv/login/")!))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Cookie helpers

enum RezkaCookies {
    static func clearAll(completion: @escaping () -> Void) {
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            let rezkaRecords = records.filter { $0.displayName.contains("rezka") }
            store.removeData(ofTypes: types, for: rezkaRecords, completionHandler: completion)
        }
    }
}
