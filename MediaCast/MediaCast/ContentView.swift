import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var ssdp = SSDPDiscovery()
    @StateObject private var httpServer = HTTPServer()
    @StateObject private var dlna = DLNAController()

    @State private var selectedDevice: UPnPDevice?
    @State private var selectedVideo: URL?
    @State private var castingTitle: String = ""
    @State private var showCastControls = false

    @AppStorage("auto_connect") private var autoConnect = false

    private var isCasting: Bool {
        dlna.transportState != .noMediaPresent && dlna.transportState != .stopped
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView {
                HomeView(
                    httpServer: httpServer,
                    dlna: dlna,
                    selectedDevice: selectedDevice,
                    castingTitle: $castingTitle
                )
                .tabItem { Label("Главная", systemImage: "house") }

                FilePickerView(
                    selectedVideo: $selectedVideo,
                    httpServer: httpServer,
                    dlna: dlna,
                    selectedDevice: $selectedDevice,
                    castingTitle: $castingTitle
                )
                .tabItem { Label("Files", systemImage: "folder") }

                SettingsView(ssdp: ssdp, selectedDevice: $selectedDevice)
                    .tabItem { Label("Настройки", systemImage: "gear") }
            }
            .tint(Theme.accent)
            .preferredColorScheme(.dark)
            .background(Theme.bgPrimary.ignoresSafeArea())

            // Floating cast bar — appears above the tab bar while casting
            if isCasting {
                CastBar(dlna: dlna, title: castingTitle) {
                    showCastControls = true
                }
                .padding(.bottom, 54)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: isCasting)
        .sheet(isPresented: $showCastControls) {
            CastControlSheet(dlna: dlna, title: castingTitle, isPresented: $showCastControls)
        }
        .onAppear {
            ssdp.startDiscovery()
            try? httpServer.start()
            UITabBar.appearance().barTintColor = UIColor(Theme.bgPrimary)
            UITabBar.appearance().backgroundColor = UIColor(Theme.bgPrimary)
            UITabBar.appearance().unselectedItemTintColor = UIColor(Theme.textMuted)
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
                UserDefaults.standard.set(device.location, forKey: "last_device_location")
                UserDefaults.standard.set(device.friendlyName, forKey: "last_device_name")
            }
        }
        // Auto-connect: when a previously connected device is discovered, select it
        .onChange(of: ssdp.devices) { _, devices in
            guard autoConnect, selectedDevice == nil else { return }
            let lastLoc = UserDefaults.standard.string(forKey: "last_device_location") ?? ""
            guard !lastLoc.isEmpty else { return }
            if let match = devices.first(where: { $0.location == lastLoc }) {
                selectedDevice = match
            }
        }
    }
}
