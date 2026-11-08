//
//  GametimeMapperUIApp.swift
//  GametimeMapperUI
//
//  Created by Ingun Jon on 11/7/26.
//

import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct GametimeMapperUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private static func pathArgument(_ names: Set<String>) -> URL? {
        let arguments = CommandLine.arguments.dropFirst()
        guard let optionIndex = arguments.firstIndex(where: { names.contains($0) }),
              arguments.index(after: optionIndex) < arguments.endIndex else { return nil }
        let path = arguments[arguments.index(after: optionIndex)]
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private let outputURL = pathArgument(["--output", "-o"])
    private let launchVideoURL = pathArgument(["--video", "-v"])

    var body: some Scene {
        WindowGroup {
            ContentView(outputURL: outputURL, launchVideoURL: launchVideoURL)
        }
    }
}
