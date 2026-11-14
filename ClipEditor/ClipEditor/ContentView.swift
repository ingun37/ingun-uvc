import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

private enum TeamNames {
    static let teamLongNames: [String: String] = [
        "ATL": "Hawks",
        "BOS": "Celtics",
        "BKN": "Nets",
        "CHA": "Hornets",
        "CHI": "Bulls",
        "CLE": "Cavs",
        "DAL": "Mavs",
        "DEN": "Nuggets",
        "DET": "Pistons",
        "GSW": "Warriors",
        "HOU": "Rockets",
        "IND": "Pacers",
        "LAC": "Clippers",
        "LAL": "Lakers",
        "MEM": "Grizzlies",
        "MIA": "Heat",
        "MIL": "Bucks",
        "MIN": "Wolves",
        "NOP": "Pelicans",
        "NYK": "Knicks",
        "OKC": "Thunder",
        "ORL": "Magic",
        "PHI": "76ers",
        "PHX": "Suns",
        "POR": "Blazers",
        "SAC": "Kings",
        "SAS": "Spurs",
        "TOR": "Raptors",
        "UTA": "Jazz",
        "WAS": "Wizards",
    ]
}

private enum InputKind: String, CaseIterable, Hashable {
    case video = "Video"
    case mapping = "Game time mapping JSON"
    case attempts = "Field goal attempts CSV"

    var types: [UTType] {
        switch self {
        case .video: [.movie, .video]
        case .mapping: [.json]
        case .attempts: [.commaSeparatedText]
        }
    }
}

private final class FileAccess {
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

@MainActor @Observable
private final class EditorModel {
    enum Scene { case choose, edit, compilation }

    var scene: Scene = .choose
    var clips: [Clip] = []
    var unmatched: [String] = []
    var videoDuration = 0.0
    var teams: [String] = []
    var gameDate: String?
    var message = ""
    var isBusy = false
    var exportedURL: URL?
    var playerExportURLs: [URL] = []
    private var files: [InputKind: FileAccess] = [:]

    var videoURL: URL? { files[.video]?.url }
    var canContinue: Bool { InputKind.allCases.allSatisfy { files[$0] != nil } && !isBusy }
    var selectedClips: [Clip] { clips.filter(\.included) }
    var playerGroups: [(key: String, name: String, clips: [Clip])] {
        let keys = Array(Set(selectedClips.flatMap(\.players))).sorted()
        return keys.map { key in
            (key, String(key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).last ?? ""),
             selectedClips.filter { $0.players.contains(key) })
        }
    }

    func name(for kind: InputKind) -> String { files[kind]?.url.lastPathComponent ?? "Choose file…" }

    func accept(_ url: URL, for kind: InputKind) -> Bool {
        guard url.isFileURL,
              let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
              kind.types.contains(where: { type.conforms(to: $0) }) else { return false }
        files[kind] = FileAccess(url)
        clips = []
        unmatched = []
        exportedURL = nil
        playerExportURLs = []
        message = ""
        return true
    }

    func choose(_ kind: InputKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            _ = accept(url, for: kind)
        }
    }

    func prepare() async {
        guard let video = videoURL,
              let mapping = files[.mapping]?.url,
              let attempts = files[.attempts]?.url else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let asset = AVURLAsset(url: video)
            guard try await !asset.loadTracks(withMediaType: .video).isEmpty else {
                throw VideoCompilation.CompilationError.noVideo
            }
            let duration = try await asset.load(.duration).seconds
            let ranges = try JSONDecoder().decode([ClockRange].self, from: Data(contentsOf: mapping))
            let csv = try String(contentsOf: attempts, encoding: .utf8)
            teams = try ClipPlanner.teams(from: csv)
            let shots = try ClipPlanner.attempts(from: csv)
            let plan = try ClipPlanner.plan(attempts: shots, ranges: ranges, videoDuration: duration)
            videoDuration = duration
            clips = plan.clips
            unmatched = plan.unmatched
            message = plan.clips.isEmpty ? "No missed attempts matched the game time mapping." : ""
            scene = .edit
        } catch {
            message = error.localizedDescription
        }
    }

    func export(to outputURL: URL? = nil) async {
        guard let video = videoURL, !selectedClips.isEmpty else { return }
        let destination: URL
        if let outputURL {
            destination = outputURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "Missed Field Goals.mp4"
            guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
            destination = selectedURL
        }
        let access = FileAccess(destination)
        let groups = playerGroups
        isBusy = true
        message = "Exporting compilation…"
        defer { isBusy = false; _ = access }
        do {
            try await VideoCompilation.export(videoURL: video, clips: selectedClips, destination: destination)
            var playerURLs: [URL] = []
            var usedNames: Set<String> = [destination.lastPathComponent.lowercased()]
            let compilationName = destination.deletingPathExtension().lastPathComponent
            let dateText = gameDate ?? compilationName.components(separatedBy: " | ").last.flatMap {
                $0 == compilationName ? nil : $0
            } ?? "Unknown date"
            let shortDate = dateText.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? dateText
            for group in groups {
                let safeName = group.name.replacingOccurrences(of: #"[^\p{L}\p{N}._ -]"#,
                    with: "_", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
                let team = String(group.key.split(separator: "|", maxSplits: 1,
                    omittingEmptySubsequences: false).first ?? "")
                let opponent = teams.first { $0 != team } ?? "Unknown team"
                let opponentName = TeamNames.teamLongNames[opponent] ?? opponent
                let base = "\(safeName.isEmpty ? "Unknown player" : safeName) | every brick VS \(opponentName) | \(dateText)"
                var name = base
                var suffix = 2
                while usedNames.contains("\(name).mp4".lowercased()) {
                    name = "\(base) \(suffix)"
                    suffix += 1
                }
                usedNames.insert("\(name).mp4".lowercased())
                let url = destination.deletingLastPathComponent().appendingPathComponent("\(name).mp4")
                message = "Exporting \(group.name)…"
                try await VideoCompilation.export(videoURL: video, clips: group.clips, destination: url,
                                                  title: group.name,
                                                  subtitle: "Every 🧱 VS \(opponent) | \(shortDate)",
                                                  player: group.key, square: true)
                playerURLs.append(url)
            }
            exportedURL = destination
            playerExportURLs = playerURLs
            message = "Saved compilation and \(playerURLs.count) player videos to \(destination.deletingLastPathComponent().path)."
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ContentView: View {
    let videoURL: URL?
    let mappingURL: URL?
    let attemptsURL: URL?
    let outputURL: URL?
    let gameDate: String?
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    @State private var model = EditorModel()
    @State private var didLoadLaunchInputs = false

    init(videoURL: URL? = nil, mappingURL: URL? = nil,
         attemptsURL: URL? = nil, outputURL: URL? = nil, gameDate: String? = nil) {
        self.videoURL = videoURL
        self.mappingURL = mappingURL
        self.attemptsURL = attemptsURL
        self.outputURL = outputURL
        self.gameDate = gameDate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ClipEditor").font(.largeTitle.bold())
                Spacer()
                Text(stepTitle).foregroundStyle(.secondary)
                Text("Version \(version) (\(build))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Divider()
            switch model.scene {
            case .choose: chooseScene
            case .edit: editScene
            case .compilation: compilationScene
            }
            if !model.message.isEmpty {
                Text(model.message)
                    .foregroundStyle(model.exportedURL == nil ? .orange : .green)
                    .accessibilityIdentifier("statusMessage")
            }
        }
        .padding(24)
        .frame(minWidth: 850, minHeight: 620)
        .onAppear {
            guard !didLoadLaunchInputs else { return }
            didLoadLaunchInputs = true
            model.gameDate = gameDate
            var invalidPaths: [String] = []
            for (kind, url) in [(InputKind.video, videoURL), (.mapping, mappingURL),
                                (.attempts, attemptsURL)] {
                if let url, !model.accept(url, for: kind) {
                    invalidPaths.append("\(kind.rawValue): \(url.path)")
                }
            }
            if !invalidPaths.isEmpty {
                model.message = "Could not use launch inputs: \(invalidPaths.joined(separator: ", "))."
            }
        }
    }

    private var stepTitle: String {
        switch model.scene {
        case .choose: "1 of \(outputURL == nil ? 3 : 2) · Choose files"
        case .edit: "2 of \(outputURL == nil ? 3 : 2) · Edit clips"
        case .compilation: "3 of 3 · Compilation"
        }
    }

    private var chooseScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Choose the source video and its game data.")
                .font(.title2)
            ForEach(InputKind.allCases, id: \.self) { kind in
                HStack {
                    Text(kind.rawValue).frame(width: 230, alignment: .leading)
                    Text(model.name(for: kind))
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") { model.choose(kind) }
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .dropDestination(for: URL.self) { urls, _ in
                    guard urls.count == 1, let url = urls.first else { return false }
                    return model.accept(url, for: kind)
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(model.isBusy ? "Reading files…" : "Next") {
                    Task { await model.prepare() }
                }
                .disabled(!model.canContinue)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var editScene: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Missed field goals").font(.title2.bold())
                Spacer()
                Text("\(model.clips.count) clips · \(model.selectedClips.count) included")
                    .foregroundStyle(.secondary)
            }
            if !model.unmatched.isEmpty {
                DisclosureGroup("\(model.unmatched.count) attempts could not be mapped") {
                    ForEach(model.unmatched, id: \.self) { Text($0).font(.caption) }
                }
            }
            ScrollView {
                LazyVStack(spacing: 18) {
                    ForEach($model.clips) { $clip in
                        if let videoURL = model.videoURL {
                            ClipRow(clip: $clip, videoURL: videoURL, videoDuration: model.videoDuration)
                        }
                    }
                }
            }
            HStack {
                Button("Back") { model.scene = .choose }
                Spacer()
                Button(outputURL == nil ? "Next" : (model.isBusy ? "Exporting…" : "Export")) {
                    if let outputURL {
                        Task { await model.export(to: outputURL) }
                    } else {
                        model.scene = .compilation
                    }
                }
                    .disabled(model.selectedClips.isEmpty || model.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var compilationScene: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Compilation").font(.title2.bold())
            Text("\(model.selectedClips.count) included clips · \(ClipPlanner.clockLabel(model.selectedClips.reduce(0) { $0 + $1.end - $1.start })) total")
            Text("Video cuts at each clip boundary. Audio extends across the cut and fades between clips where source audio is available.")
                .foregroundStyle(.secondary)
            if let url = model.exportedURL {
                HStack {
                    Text(url.path).lineLimit(1).truncationMode(.middle)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
            }
            if !model.playerExportURLs.isEmpty {
                Text("Player videos: \(model.playerExportURLs.map(\.lastPathComponent).joined(separator: ", "))")
                    .textSelection(.enabled)
            }
            Spacer()
            HStack {
                Button("Back") { model.scene = .edit }
                Spacer()
                Button(model.isBusy ? "Exporting…" : "Choose Save Location and Export") {
                    Task { await model.export() }
                }
                .disabled(model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
    }
}

private struct ClipRow: View {
    @Binding var clip: Clip
    let videoURL: URL
    let videoDuration: Double

    private var minimumLength: Double { min(1, clip.originalEnd - clip.originalStart) }
    private var startRange: ClosedRange<Double> {
        max(0, clip.originalStart - 12)...min(clip.originalStart + 12, clip.end - minimumLength)
    }
    private var endRange: ClosedRange<Double> {
        max(clip.originalEnd - 12, clip.start + minimumLength)...min(videoDuration, clip.originalEnd + 12)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ClipPreview(url: videoURL, start: clip.start, end: clip.end)
                .frame(width: 320, height: 180)
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Include in compilation", isOn: $clip.included)
                Text(clip.descriptions.joined(separator: " · "))
                    .font(.headline)
                    .lineLimit(2)
                Text("Game time: \(clip.gameTimes.joined(separator: " · "))")
                    .monospacedDigit().foregroundStyle(.secondary)
                if !clip.captions.isEmpty {
                    Text("FGM/FGA captions: \(clip.captions.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " · "))")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Text("\(ClipPlanner.clockLabel(clip.start)) – \(ClipPlanner.clockLabel(clip.end))")
                    .monospacedDigit().foregroundStyle(.secondary)
                HStack {
                    Text("Start")
                    Slider(value: $clip.start, in: startRange)
                    Text(ClipPlanner.clockLabel(clip.start)).monospacedDigit()
                }
                HStack {
                    Text("End")
                    Slider(value: $clip.end, in: endRange)
                    Text(ClipPlanner.clockLabel(clip.end)).monospacedDigit()
                }
                Button("Reset timing") {
                    clip.start = clip.originalStart
                    clip.end = clip.originalEnd
                }
                .disabled(clip.start == clip.originalStart && clip.end == clip.originalEnd)
                Text("Drag either edge to include more or less source video.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ClipPreview: View {
    let url: URL
    let start: Double
    let end: Double
    @State private var player = AVPlayer()

    var body: some View {
        NativePlayerView(player: player)
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                resetRange()
            }
            .onChange(of: start) { _, _ in resetRange() }
            .onChange(of: end) { _, _ in resetRange() }
            .onReceive(NotificationCenter.default.publisher(for: AVPlayerItem.didPlayToEndTimeNotification)) { notification in
                guard let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
                player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
            }
            .onDisappear {
                player.pause()
                player.replaceCurrentItem(with: nil)
            }
    }

    private func resetRange() {
        player.pause()
        player.currentItem?.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600))
    }
}

// AVKit's SwiftUI VideoPlayer bridge can abort during metadata initialization in
// archived Release builds. Use the native macOS player view directly instead.
private struct NativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

#Preview { ContentView() }
