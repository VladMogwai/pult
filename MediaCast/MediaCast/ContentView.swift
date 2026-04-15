import SwiftUI

struct ContentView: View {
    @StateObject private var ssdp = SSDPDiscovery()
    @StateObject private var httpServer = HTTPServer()
    @StateObject private var dlna = DLNAController()

    @State private var selectedDevice: UPnPDevice?
    @State private var selectedVideo: URL?

    var body: some View {
        TabView {
            DeviceListView(ssdp: ssdp, selectedDevice: $selectedDevice)
                .tabItem { Label("Devices", systemImage: "tv") }

            FilePickerView(selectedVideo: $selectedVideo, httpServer: httpServer)
                .tabItem { Label("Files", systemImage: "folder") }

            PlayerControlView(
                dlna: dlna,
                httpServer: httpServer,
                selectedVideo: selectedVideo,
                selectedDevice: selectedDevice
            )
            .tabItem { Label("Remote", systemImage: "play.rectangle") }
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
        .onChange(of: selectedDevice) { _, device in
            if let device {
                dlna.selectDevice(device)
                ssdp.stopAllScanning()
            }
        }
    }
}
