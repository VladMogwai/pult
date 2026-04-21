//
//  MediaCastApp.swift
//  MediaCast
//
//  Created by Vlad Arefiev on 15.04.2026.
//

import SwiftUI
import UIKit

@main
struct MediaCastApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onReceive(NotificationCenter.default.publisher(
                    for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    // Re-open security scope for custom download directory.
                    // iOS revokes all security scopes when the app is backgrounded.
                    DownloadManager.shared.restoreSecurityScope()
                }
        }
    }
}
