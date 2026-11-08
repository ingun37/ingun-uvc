import AppKit
import Foundation
import Observation
import SwiftUI

private struct Game: Identifiable {
    let id: String
    let date: String
    let teams: String

    static func parse(_ output: String) -> [Game] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 3, parts[0].count == 10,
                  parts[0].allSatisfy(\.isNumber) else { return nil }
            return Game(id: String(parts[0]), date: String(parts[1]),
                        teams: parts.dropFirst(2).joined(separator: " "))
        }
    }
}

private enum Runner {
    nonisolated static let root: URL = {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appending(path: "data_fetcher").path) { return cwd }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }()

    nonisolated static func executable(_ relativePath: String) throws -> URL {
        let url = root.appending(path: relativePath)
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            throw RunError.missing(relativePath)
        }
        return url
    }

    nonisolated static func run(_ executable: URL, arguments: [String], environment: [String: String] = [:]) throws -> String {
        let output = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let error = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: error)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        process.waitUntilExit()
        let stderr = (try? String(contentsOf: error, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError.failed(stderr.isEmpty ? "Process exited with status \(process.terminationStatus)." : stderr)
        }
        return (try? String(contentsOf: output, encoding: .utf8)) ?? ""
    }

    nonisolated static func appExecutable(_ relativePath: String, name: String) throws -> URL {
        let bundle = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: bundle.path) else { throw RunError.missing(relativePath) }
        return try executable(relativePath + "/Contents/MacOS/" + name)
    }

    enum RunError: LocalizedError {
        case missing(String), failed(String), missingOutput(String)
        var errorDescription: String? {
            switch self {
            case .missing(let path): "Required executable is missing: \(path)"
            case .failed(let message): message.trimmingCharacters(in: .whitespacesAndNewlines)
            case .missingOutput(let path): "The app closed without creating \(path)."
            }
        }
    }
}

@MainActor @Observable
private final class Workflow {
    enum Scene { case games, attempts, mapper, editor, done }
    var scene: Scene = .games
    var page = "1"
    var games: [Game] = []
    var message = ""
    var busy = false
    var selectedGame: Game?
    private let tempDirectory = FileManager.default.temporaryDirectory
        .appending(path: "unified-app-\(UUID().uuidString)", directoryHint: .isDirectory)
    private var csvURL: URL { tempDirectory.appending(path: "attempts.csv") }
    private var jsonURL: URL { tempDirectory.appending(path: "mapping.json") }
    private var videoPathURL: URL { tempDirectory.appending(path: "video-path.txt") }

    func query() async {
        guard let number = Int(page), number > 0 else { message = "Enter a positive page number."; return }
        busy = true
        message = "Querying games…"
        defer { busy = false }
        do {
            let executable = try Runner.executable("data_fetcher/dist/main")
            let output = try await Task.detached { try Runner.run(executable, arguments: ["games", "--page", String(number)]) }.value
            games = Game.parse(output)
            message = games.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        } catch { message = error.localizedDescription }
    }

    func select(_ game: Game) async {
        selectedGame = game
        scene = .attempts
        busy = true
        message = "Fetching attempts for \(game.id)…"
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
            let executable = try Runner.executable("data_fetcher/dist/main")
            let csv = csvURL
            _ = try await Task.detached { try Runner.run(executable, arguments: ["attempts", game.id, "--output", csv.path]) }.value
            guard FileManager.default.fileExists(atPath: csv.path) else { throw Runner.RunError.missingOutput(csv.path) }
            scene = .mapper
            message = "Open GametimeMapperUI and save the mapping."
            await runMapper()
        } catch { message = error.localizedDescription }
    }

    func runMapper() async {
        busy = true
        defer { busy = false }
        do {
            let executable = try Runner.appExecutable("GametimeMapper/build/GametimeMapperUI.app", name: "GametimeMapperUI")
            let json = jsonURL
            let handoff = videoPathURL
            _ = try await Task.detached {
                try Runner.run(executable, arguments: ["--output", json.path],
                               environment: ["UNIFIED_APP_VIDEO_PATH_FILE": handoff.path])
            }.value
            guard FileManager.default.fileExists(atPath: json.path) else { throw Runner.RunError.missingOutput(json.path) }
            let videoPath = try String(contentsOf: handoff, encoding: .utf8)
            guard !videoPath.isEmpty else { throw Runner.RunError.missingOutput(handoff.path) }
            scene = .editor
            message = "ClipEditor is open. Finish the compilation there."
            await runEditor(videoPath: videoPath)
        } catch { message = error.localizedDescription }
    }

    func runEditor(videoPath: String) async {
        busy = true
        defer { busy = false }
        do {
            let executable = try Runner.appExecutable("ClipEditor/build/ClipEditor.app", name: "ClipEditor")
            let arguments = ["--video", videoPath, "--json", jsonURL.path, "--csv", csvURL.path]
            _ = try await Task.detached { try Runner.run(executable, arguments: arguments) }.value
            scene = .done
            message = "ClipEditor closed."
        } catch { message = error.localizedDescription }
    }
}

struct ContentView: View {
    @State private var workflow = Workflow()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Unified App").font(.largeTitle.bold())
            Divider()
            switch workflow.scene {
            case .games:
                HStack {
                    Text("Page")
                    TextField("Page number", text: $workflow.page).frame(width: 90)
                    Button("Query") { Task { await workflow.query() } }.disabled(workflow.busy)
                }
                List(workflow.games) { game in
                    Button {
                        Task { await workflow.select(game) }
                    } label: {
                        HStack {
                            Text(game.date).frame(width: 110, alignment: .leading)
                            Text(game.teams)
                            Spacer()
                            Text(game.id).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            case .attempts, .mapper, .editor:
                if workflow.busy {
                    ProgressView(workflow.scene == .attempts ? "Fetching attempts…" :
                                 workflow.scene == .mapper ? "Waiting for GametimeMapperUI…" :
                                 "Waiting for ClipEditor…")
                } else if workflow.scene == .attempts, let game = workflow.selectedGame {
                    Button("Retry fetching attempts") { Task { await workflow.select(game) } }
                    Button("Back to games") { workflow.scene = .games }
                } else if workflow.scene == .mapper {
                    Button("Retry GametimeMapperUI") { Task { await workflow.runMapper() } }
                }
                Spacer()
            case .done:
                Label("Workflow complete", systemImage: "checkmark.circle.fill")
                Spacer()
            }
            if !workflow.message.isEmpty {
                Text(workflow.message).textSelection(.enabled)
            }
        }
        .padding(24)
        .frame(minWidth: 700, minHeight: 500)
    }
}
