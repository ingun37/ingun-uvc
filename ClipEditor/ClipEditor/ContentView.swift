import AVFoundation
import AVKit
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

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
    var message = ""
    var isBusy = false
    var exportedURL: URL?
    private var files: [InputKind: FileAccess] = [:]

    var videoURL: URL? { files[.video]?.url }
    var canContinue: Bool { InputKind.allCases.allSatisfy { files[$0] != nil } && !isBusy }
    var selectedClips: [Clip] { clips.filter(\.included) }

    func name(for kind: InputKind) -> String { files[kind]?.url.lastPathComponent ?? "Choose file…" }

    func choose(_ kind: InputKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = kind.types
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            files[kind] = FileAccess(url)
            clips = []
            unmatched = []
            exportedURL = nil
            message = ""
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

    func export() async {
        guard let video = videoURL, !selectedClips.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = "Missed Field Goals.mp4"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let access = FileAccess(destination)
        isBusy = true
        message = "Exporting compilation…"
        defer { isBusy = false; _ = access }
        do {
            try await VideoCompilation.export(videoURL: video, clips: selectedClips, destination: destination)
            exportedURL = destination
            message = "Compilation saved."
        } catch {
            message = error.localizedDescription
        }
    }
}

struct ContentView: View {
    @State private var model = EditorModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("ClipEditor").font(.largeTitle.bold())
                Spacer()
                Text(stepTitle).foregroundStyle(.secondary)
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
    }

    private var stepTitle: String {
        switch model.scene {
        case .choose: "1 of 3 · Choose files"
        case .edit: "2 of 3 · Edit clips"
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
                Button("Next") { model.scene = .compilation }
                    .disabled(model.selectedClips.isEmpty)
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
                Text("\(ClipPlanner.clockLabel(clip.start)) – \(ClipPlanner.clockLabel(clip.end))")
                    .monospacedDigit().foregroundStyle(.secondary)
                HStack {
                    Text("Start")
                    Slider(value: $clip.start, in: 0...max(0, clip.end - 1))
                    Text(ClipPlanner.clockLabel(clip.start)).monospacedDigit()
                }
                HStack {
                    Text("End")
                    Slider(value: $clip.end, in: min(videoDuration, clip.start + 1)...videoDuration)
                    Text(ClipPlanner.clockLabel(clip.end)).monospacedDigit()
                }
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
        VideoPlayer(player: player)
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

#Preview { ContentView() }
