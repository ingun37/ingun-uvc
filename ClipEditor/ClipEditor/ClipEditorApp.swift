//
//  ClipEditorApp.swift
//  ClipEditor
//
//  Created by Ingun Jon on 10/29/26.
//

import AppKit
import SwiftUI

private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct ClipEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static func pathArgument(_ names: Set<String>) -> URL? {
        let arguments = CommandLine.arguments.dropFirst()
        guard let optionIndex = arguments.firstIndex(where: { names.contains($0) }),
              arguments.index(after: optionIndex) < arguments.endIndex else { return nil }
        let path = arguments[arguments.index(after: optionIndex)]
        guard !path.isEmpty, !path.hasPrefix("-") else { return nil }
        return URL(fileURLWithPath: path)
    }

    private let videoURL = pathArgument(["--video", "-v"])
    private let mappingURL = pathArgument(["--json", "-j"])
    private let attemptsURL = pathArgument(["--csv", "-c"])
    private let outputURL = pathArgument(["--output", "-o"])

    var body: some Scene {
        WindowGroup {
            ContentView(videoURL: videoURL, mappingURL: mappingURL,
                        attemptsURL: attemptsURL, outputURL: outputURL)
        }
    }
}
