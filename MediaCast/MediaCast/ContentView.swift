import SwiftUI

struct ContentView: View {
    @StateObject private var ssdp = SSDPDiscovery()
    @StateObject private var httpServer = HTTPServer()
    @StateObject private var dlna = DLNAController()

    @State private var selectedDevice: UPnPDevice?
    @State private var selectedVideo: URL?

    // Set by SearchView when the user resolves + picks a stream.
    // PlayerControlView watches these to start casting.
    @State private var pendingCastURL: URL?
    @State private var pendingCastTitle: String?
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DeviceListView(ssdp: ssdp, selectedDevice: $selectedDevice)
                .tabItem { Label("Devices", systemImage: "tv") }
                .tag(0)

            FilePickerView(selectedVideo: $selectedVideo, httpServer: httpServer)
                .tabItem { Label("Files", systemImage: "folder") }
                .tag(1)

            SearchView(
                httpServer: httpServer,
                pendingCastURL: $pendingCastURL,
                pendingCastTitle: $pendingCastTitle
            )
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(2)

            PlayerControlView(
                dlna: dlna,
                httpServer: httpServer,
                selectedVideo: selectedVideo,
                selectedDevice: selectedDevice,
                pendingCastURL: $pendingCastURL,
                pendingCastTitle: $pendingCastTitle
            )
            .tabItem { Label("Remote", systemImage: "play.rectangle") }
            .tag(3)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(4)
        }
        .onAppear {
            ssdp.startDiscovery()
            try? httpServer.start()
        }
        .onDisappear {
            ssdp.stopDiscovery()
            httpServer.stop()
            dlna.stopPolling()
        }
        .onChange(of: selectedDevice) { (_: UPnPDevice?, device: UPnPDevice?) in
            if let device {
                dlna.selectDevice(device)
                ssdp.stopAllScanning()
            }
        }
        // Auto-switch to Remote tab when Search resolves a stream.
        .onChange(of: pendingCastURL) { _, url in
            if url != nil { selectedTab = 3 }
        }
    }
}
