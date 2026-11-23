import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class SelectedBoxScore {
    let url: URL
    private let hasSecurityScope: Bool

    init(url: URL) {
        self.url = url
        hasSecurityScope = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
    }
}

private final class GeneratedVideo {
    let url: URL

    init(url: URL) { self.url = url }

    deinit { try? FileManager.default.removeItem(at: url) }
}

struct ContentView: View {
    private enum Scene { case input, player }

    @State private var scene: Scene = .input
    @State private var selectedFile: SelectedBoxScore?
    @State private var boxScore: BoxScore?
    @State private var selectedPlayerID: String?
    @State private var generatedVideo: GeneratedVideo?
    @State private var player: AVPlayer?
    @State private var isGenerating = false
    @State private var errorMessage: String?

    private var selectedPlayer: BoxScorePlayer? {
        boxScore?.players.first { $0.id == selectedPlayerID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Player Boxscore Playground").font(.largeTitle.bold())
            switch scene {
            case .input: inputScene
            case .player: playerScene
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 540)
    }

    private var inputScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. Choose a boxscore CSV").font(.title2)
            Button("Choose CSV") { chooseFile() }
            if let selectedFile {
                Text(selectedFile.url.path).textSelection(.enabled)
            }
            Button("Next") { loadBoxScore() }
                .disabled(selectedFile == nil)
        }
    }

    private var playerScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. Choose a player and generate the video").font(.title2)
            Picker("Player", selection: $selectedPlayerID) {
                Text("Select a player").tag(String?.none)
                if let boxScore {
                    ForEach(boxScore.players) { boxScorePlayer in
                        Text("\(boxScorePlayer.name) (\(boxScorePlayer.team))")
                            .tag(Optional(boxScorePlayer.id))
                    }
                }
            }
            .frame(maxWidth: 400)
            .disabled(isGenerating)
            .onChange(of: selectedPlayerID) { _, _ in clearPreview() }

            HStack {
                Button("Back") {
                    clearPreview()
                    scene = .input
                    errorMessage = nil
                }
                .disabled(isGenerating)
                Button("Generate") { Task { await generateVideo() } }
                    .disabled(selectedPlayer == nil || isGenerating)
            }

            if isGenerating {
                ProgressView("Generating boxscore video…")
            } else if let player {
                VideoPlayer(player: player)
                    .frame(maxWidth: 500, minHeight: 320)
                    .background(.black)
                HStack {
                    Button("Play") { player.play() }
                    Button("Pause") { player.pause() }
                    Button("Replay") {
                        player.seek(to: .zero)
                        player.play()
                    }
                }
                if let generatedVideo {
                    Text("Preview file: \(generatedVideo.url.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedFile = SelectedBoxScore(url: url)
        boxScore = nil
        selectedPlayerID = nil
        clearPreview()
        errorMessage = nil
    }

    private func loadBoxScore() {
        guard let selectedFile else { return }
        do {
            let csv = try String(contentsOf: selectedFile.url, encoding: .utf8)
            boxScore = try BoxScore(csv: csv)
            selectedPlayerID = nil
            errorMessage = nil
            scene = .player
        } catch {
            errorMessage = "Could not load the boxscore CSV: \(error.localizedDescription)"
        }
    }

    private func clearPreview() {
        player?.pause()
        player = nil
        generatedVideo = nil
    }

    private func generateVideo() async {
        guard let selectedPlayer else { return }
        isGenerating = true
        errorMessage = nil
        clearPreview()
        defer { isGenerating = false }

        let output = FileManager.default.temporaryDirectory
            .appending(path: "player-boxscore-\(UUID().uuidString).mp4")
        do {
            let image = try BoxScoreVideo.render(PlayerBoxScoreView(player: selectedPlayer))
            try await BoxScoreVideo.writeStill(image, size: CGSize(width: 1080, height: 1080), to: output)
            generatedVideo = GeneratedVideo(url: output)
            player = AVPlayer(url: output)
            player?.play()
        } catch {
            try? FileManager.default.removeItem(at: output)
            errorMessage = "Could not generate the video: \(error.localizedDescription)"
        }
    }
}
