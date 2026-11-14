//
//  GuraStreamingApp.swift
//  GuraStreaming
//
//  Created by Ingun Jon on 11/14/26.
//

import SwiftUI
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
@main
struct GuraStreamingApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
