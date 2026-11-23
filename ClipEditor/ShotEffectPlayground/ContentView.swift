import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private final class SelectedVideo {
    let url: URL
    private let scoped: Bool

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if scoped { url.stopAccessingSecurityScopedResource() }
    }
}

struct ContentView: View {
    private enum Step { case input, effect, details, review }

    @Environment(\.openWindow) private var openWindow
    @Environment(ShotEffectStore.self) private var shotEffects
    @State private var step: Step = .input
    @State private var selectedVideo: SelectedVideo?
    @State private var videoDuration = 0.0
    @State private var clipID = UUID()
    @State private var locX = ""
    @State private var locY = ""
    @State private var playerName = ""
    @State private var shotDescription = "Jump Shot"
    @State private var fgm = ""
    @State private var fga = ""
    @State private var outputURL: URL?
    @State private var player: AVPlayer?
    @State private var isExporting = false
    @State private var errorMessage: String?

    private var effectKey: ShotEffectKey { ShotEffectKey(clipID: clipID, attemptIndex: 0) }
    private var selectedEffect: AppliedShotEffect? { shotEffects.effects[effectKey] }
    private var location: CGPoint? {
        guard let x = Double(locX), let y = Double(locY), x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }
    private var makes: Int? { Int(fgm) }
    private var attempts: Int? { Int(fga) }
    private var detailsAreValid: Bool {
        guard location != nil, !playerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !shotDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let makes, let attempts else { return false }
        return attempts > 0 && makes >= 0 && makes <= attempts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Shot Effect Playground").font(.largeTitle.bold())
            switch step {
            case .input: inputScene
            case .effect: effectScene
            case .details: detailsScene
            case .review: reviewScene
            }
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(minWidth: 660, minHeight: 480)
    }

    private var inputScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("1. Choose a video").font(.title2)
            Button("Choose Video") { chooseVideo() }
            if let selectedVideo { Text(selectedVideo.url.path).textSelection(.enabled) }
            Button("Next") {
                step = .effect
                Task { await loadVideoAndOpenEditor() }
            }
            .disabled(selectedVideo == nil)
        }
    }

    private var effectScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("2. Choose the release frame and player").font(.title2)
            Text("Select a frame, click the shooter, adjust the bounding box, and click Apply in the shot effect window. Close that window when finished.")
                .fixedSize(horizontal: false, vertical: true)
            if videoDuration > 0 {
                Button("Open Shot Effect") { openEffectEditor() }
            } else if errorMessage != nil {
                Button("Try Again") { Task { await loadVideoAndOpenEditor() } }
            } else {
                ProgressView("Loading video…")
            }
            if let selectedEffect {
                Label("Effect applied at \(selectedEffect.timestamp, specifier: "%.3f") s", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            HStack {
                Button("Back") { step = .input }
                Button("Next") { step = .details; errorMessage = nil }
                    .disabled(selectedEffect == nil)
            }
        }
    }

    private var detailsScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("3. Add shot information").font(.title2)
            Text("Shot location uses loc_x and loc_y in tenths of a foot.")
                .foregroundStyle(.secondary)
            Form {
                TextField("loc_x", text: $locX)
                TextField("loc_y", text: $locY)
                TextField("Player last name", text: $playerName)
                TextField("Shot description", text: $shotDescription)
                TextField("FGM", text: $fgm)
                TextField("FGA", text: $fga)
            }
            .frame(maxWidth: 420)
            HStack {
                Button("Back") { step = .effect }
                Button("Next") {
                    step = .review
                    Task { await generateVideo() }
                }
                .disabled(!detailsAreValid)
            }
        }
    }

    private var reviewScene: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("4. Review the video").font(.title2)
            if isExporting {
                ProgressView("Generating shot effect video…")
            } else if let player {
                VideoPlayer(player: player)
                    .frame(minHeight: 320)
                    .background(.black)
                HStack {
                    Button("Play") { player.play() }
                    Button("Pause") { player.pause() }
                    Button("Replay") {
                        player.seek(to: .zero)
                        player.play()
                    }
                }
                if let outputURL {
                    Text("Preview file: \(outputURL.path)").font(.caption)
                        .foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            HStack {
                Button("Back") {
                    player?.pause()
                    step = .details
                }
                Button("Generate Again") { Task { await generateVideo() } }
                    .disabled(isExporting)
            }
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        selectedVideo = SelectedVideo(url)
        videoDuration = 0
        shotEffects.effects.removeValue(forKey: effectKey)
        clipID = UUID()
        locX = ""
        locY = ""
        playerName = ""
        shotDescription = "Jump Shot"
        fgm = ""
        fga = ""
        player?.pause()
        player = nil
        outputURL = nil
        errorMessage = nil
    }

    private func loadVideoAndOpenEditor() async {
        guard let url = selectedVideo?.url else { return }
        do {
            let duration = try await AVURLAsset(url: url).load(.duration).seconds
            guard duration.isFinite, duration > 0.05 else {
                throw PlaygroundError.invalidVideo
            }
            guard selectedVideo?.url == url, step == .effect else { return }
            videoDuration = duration
            errorMessage = nil
            openEffectEditor()
        } catch {
            errorMessage = "Could not open the video: \(error.localizedDescription)"
        }
    }

    private func openEffectEditor() {
        guard let url = selectedVideo?.url, videoDuration > 0 else { return }
        openWindow(value: ShotEffectWindow(clipID: clipID, attemptIndex: 0,
                                           videoURL: url, clipStart: 0,
                                           attemptTime: videoDuration - 0.01,
                                           playerID: nil, playerName: "Player",
                                           shotDescription: "Jump Shot", shotX: nil, shotY: nil))
    }

    private func generateVideo() async {
        guard let url = selectedVideo?.url, let selectedEffect,
              let location, let makes, let attempts, detailsAreValid else { return }
        isExporting = true
        errorMessage = nil
        player?.pause()
        player = nil
        defer { isExporting = false }
        do {
            let mapping = try CourtSpotMap.bundled()
            guard let spotLabel = mapping.nearestLabel(to: location) else {
                throw ShotEffectError.missingCourtSpot
            }
            let effect = AppliedShotEffect(
                timestamp: selectedEffect.timestamp, bounds: selectedEffect.bounds,
                frameSize: selectedEffect.frameSize, maskPNG: selectedEffect.maskPNG,
                maskPixels: selectedEffect.maskPixels, playerID: nil,
                playerName: playerName.trimmingCharacters(in: .whitespacesAndNewlines),
                shotDescription: shotDescription.trimmingCharacters(in: .whitespacesAndNewlines),
                shotLocation: location)
            let clip = Clip(start: 0, end: videoDuration,
                            descriptions: [effect.shotDescription],
                            attempts: [ClipAttempt(sourceTime: effect.timestamp,
                                                   text: nil, location: location, player: nil)])
            let output = FileManager.default.temporaryDirectory
                .appending(path: "shot-effect-playground-\(UUID().uuidString).mp4")
            try await VideoCompilation.export(videoURL: url, clips: [clip], destination: output,
                                              shotEffects: [ShotEffectKey(clipID: clip.id, attemptIndex: 0):
                                                  PreparedShotEffect(effect: effect,
                                                                     stats: LocalShotStats(makes: makes, attempts: attempts),
                                                                     spotLabel: spotLabel)])
            outputURL = output
            player = AVPlayer(url: output)
            player?.play()
        } catch {
            errorMessage = "Could not generate the video: \(error.localizedDescription)"
        }
    }
}

private enum PlaygroundError: LocalizedError {
    case invalidVideo
    var errorDescription: String? { "The selected video has no usable duration." }
}
