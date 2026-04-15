import SwiftUI

struct SettingsView: View {
    @State private var baseURL = APIClient.shared.baseURL
    @State private var apiKey  = APIClient.shared.apiKey
    @State private var saved   = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://your-app.onrender.com", text: $baseURL)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                } header: {
                    Text("API Server URL")
                } footer: {
                    Text("Base URL of your video-downloader backend (no trailing slash).")
                }

                Section {
                    SecureField("Optional", text: $apiKey)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("API Key")
                } footer: {
                    Text("Bearer token. Leave empty if API_KEY is not set on the server.")
                }

                Section {
                    Button("Save") {
                        APIClient.shared.baseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                        APIClient.shared.apiKey  = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                        saved = true
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .navigationTitle("Settings")
            .alert("Saved", isPresented: $saved) {
                Button("OK", role: .cancel) {}
            }
        }
    }
}
