import AVFoundation
import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

private struct Game: Identifiable {
    // Edit these values to change the names used in output filenames.
    private static let teamLongNames: [String: String] = [
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

    let id: String
    let date: String
    let teams: String
    let home: String
    let away: String

    var displayDate: String {
        let inputDate = ISO8601DateFormatter().date(from: date + "T00:00:00Z")
        return inputDate.map {
            $0.formatted(.dateTime.month(.abbreviated).day().year().locale(Locale(identifier: "en_US_POSIX")))
        } ?? date
    }

    var outputName: String {
        let homeName = Self.teamLongNames[home] ?? home
        let awayName = Self.teamLongNames[away] ?? away
        return "\(homeName) VS \(awayName) | Bricklights | \(displayDate)"
    }

    var compilationFilename: String { outputName + ".mp4" }
    var thumbnailFilename: String { outputName + ".jpg" }

    static func parse(_ output: String) -> [Game] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(whereSeparator: \.isWhitespace)
            guard parts.count >= 4, parts[0].count == 10,
                parts[0].allSatisfy(\.isNumber)
            else { return nil }
            return Game(
                id: String(parts[0]),
                date: String(parts[1]),
                teams: "\(parts[2]) vs \(parts[3])",
                home: String(parts[2]),
                away: String(parts[3])
            )
        }
    }
}

private enum Runner {
    nonisolated static let root: URL = {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(
            atPath: cwd.appending(path: "data_fetcher").path
        ) {
            return cwd
        }
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

    nonisolated static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        expectedOutput: URL? = nil
    ) throws -> String {
        let output = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString
        )
        let error = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString
        )
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: output)
            try? FileManager.default.removeItem(at: error)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment
        ) { _, new in new }
        process.standardOutput = try FileHandle(forWritingTo: output)
        process.standardError = try FileHandle(forWritingTo: error)
        try process.run()
        process.waitUntilExit()
        let stdout = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: error, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            var details = ["Process exited with status \(process.terminationStatus)."]
            if !stdout.isEmpty { details.append("Output:\n\(stdout)") }
            if !stderr.isEmpty { details.append("Error output:\n\(stderr)") }
            throw RunError.failed(details.joined(separator: "\n\n"))
        }
        if let expectedOutput,
            !FileManager.default.fileExists(atPath: expectedOutput.path)
        {
            var details = ["The app closed without creating \(expectedOutput.path)."]
            if !stdout.isEmpty { details.append("Output:\n\(stdout)") }
            if !stderr.isEmpty { details.append("Error output:\n\(stderr)") }
            throw RunError.failed(details.joined(separator: "\n\n"))
        }
        return stdout
    }

    nonisolated static func runDataFetcher(
        arguments: [String], expectedOutput: URL? = nil
    ) throws -> String
    {
        let activate = root.appending(path: "data_fetcher/.venv/bin/activate")
        let script = root.appending(path: "data_fetcher/main.py")
        guard FileManager.default.fileExists(atPath: activate.path) else {
            throw RunError.missing("data_fetcher/.venv/bin/activate")
        }
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw RunError.missing("data_fetcher/main.py")
        }
        return try run(
            URL(fileURLWithPath: "/bin/zsh"),
            arguments: [
                "-ic", "source \"$1\" && shift && exec python \"$@\"",
                "data-fetcher", activate.path, script.path,
            ] + arguments,
            expectedOutput: expectedOutput
        )
    }

    nonisolated static func appExecutable(_ relativePath: String, name: String)
        throws -> URL
    {
        let bundle = root.appending(path: relativePath)
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw RunError.missing(relativePath)
        }
        return try executable(relativePath + "/Contents/MacOS/" + name)
    }

    enum RunError: LocalizedError {
        case missing(String), failed(String), missingOutput(String)
        var errorDescription: String? {
            switch self {
            case .missing(let path): "Required executable is missing: \(path)"
            case .failed(let message):
                message.trimmingCharacters(in: .whitespacesAndNewlines)
            case .missingOutput(let path):
                "The app closed without creating \(path)."
            }
        }
    }
}

@MainActor @Observable
private final class Workflow {
    enum Scene { case games, attempts, video, mapper, editor, thumbnail, done }
    var scene: Scene = .games
    var page = "1"
    var games: [Game] = []
    var message = ""
    var busy = false
    var selectedGame: Game?
    var videoURL: URL?
    private let tempDirectory = FileManager.default.temporaryDirectory
        .appending(
            path: "unified-app-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
    private var stagedCSVURL: URL { tempDirectory.appending(path: "attempts.csv") }
    private var csvURL: URL? {
        guard let videoURL, let selectedGame else { return nil }
        return videoURL.deletingLastPathComponent().appendingPathComponent(
            "\(videoURL.deletingPathExtension().lastPathComponent)-\(selectedGame.id).csv"
        )
    }
    private var jsonURL: URL? {
        guard let videoURL else { return nil }
        return videoURL.deletingLastPathComponent().appendingPathComponent(
            "\(videoURL.deletingPathExtension().lastPathComponent)-map.json"
        )
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let selectedGame else { return }
        let csv = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.deletingPathExtension().lastPathComponent)-\(selectedGame.id).csv"
        )
        do {
            try Data(contentsOf: stagedCSVURL).write(to: csv, options: .atomic)
            videoURL = url
            scene = .mapper
            Task { await runMapper() }
        } catch { message = error.localizedDescription }
    }

    func query() async {
        guard let number = Int(page), number > 0 else {
            message = "Enter a positive page number."
            return
        }
        busy = true
        message = "Querying games…"
        defer { busy = false }
        do {
            let output = try await Task.detached {
                try Runner.runDataFetcher(arguments: [
                    "games", "--page", String(number),
                ])
            }.value
            games = Game.parse(output)
            message =
                games.isEmpty
                ? output.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        } catch { message = error.localizedDescription }
    }

    func select(_ game: Game) async {
        videoURL = nil
        selectedGame = game
        scene = .attempts
        busy = true
        message = "Fetching attempts for \(game.id)…"
        defer { busy = false }
        do {
            try FileManager.default.createDirectory(
                at: tempDirectory,
                withIntermediateDirectories: true
            )
            let csv = stagedCSVURL
            _ = try await Task.detached {
                try Runner.runDataFetcher(
                    arguments: ["attempts", game.id, "--output", csv.path],
                    expectedOutput: csv
                )
            }.value
            scene = .video
            message = "Choose the source video."
        } catch { message = error.localizedDescription }
    }

    func runMapper() async {
        guard let videoURL, let json = jsonURL else { return }
        busy = true
        defer { busy = false }
        do {
            let executable = try Runner.appExecutable(
                "TheMapper/build/TheMapper.app",
                name: "TheMapper"
            )
            _ = try await Task.detached {
                try Runner.run(
                    executable,
                    arguments: [
                        "--video", videoURL.path, "--output", json.path,
                    ]
                )
            }.value
            guard FileManager.default.fileExists(atPath: json.path) else {
                throw Runner.RunError.missingOutput(json.path)
            }
            scene = .editor
            message = "ClipEditor is open. Finish the compilation there."
            await runEditor(videoPath: videoURL.path)
        } catch { message = error.localizedDescription }
    }

    func runEditor(videoPath: String) async {
        guard let selectedGame, let json = jsonURL, let csv = csvURL else { return }
        busy = true
        defer { busy = false }
        do {
            let executable = try Runner.appExecutable(
                "ClipEditor/build/ClipEditor.app",
                name: "ClipEditor"
            )
            let video = URL(fileURLWithPath: videoPath)
            let output = video.deletingLastPathComponent()
                .appendingPathComponent(
                    selectedGame.compilationFilename
                )
            let arguments = [
                "--video", videoPath, "--json", json.path,
                "--csv", csv.path, "--output", output.path,
                "--date", selectedGame.displayDate,
            ]
            _ = try await Task.detached {
                try Runner.run(executable, arguments: arguments)
            }.value
            scene = .thumbnail
            message = "Select a frame region for the thumbnail."
        } catch { message = error.localizedDescription }
    }

    func generateThumbnail(selection: CGRect, time: Double) async {
        guard let videoURL, let selectedGame else { return }
        busy = true
        message = "Generating thumbnail…"
        defer { busy = false }
        do {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try generator.copyCGImage(
                at: CMTime(seconds: time, preferredTimescale: 600),
                actualTime: nil
            )
            let width = CGFloat(frame.width)
            let height = CGFloat(frame.height)
            let crop = CGRect(
                x: selection.minX * width,
                y: selection.minY * height,
                width: selection.width * width,
                height: selection.height * height
            ).integral
            guard let image = frame.cropping(to: crop),
                let data = NSBitmapImageRep(cgImage: image).representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.9]
                )
            else {
                throw Runner.RunError.failed(
                    "Could not crop the selected frame region."
                )
            }
            let background = tempDirectory.appending(
                path: "thumbnail-background.jpg"
            )
            try data.write(to: background)
            let output = videoURL.deletingLastPathComponent()
                .appendingPathComponent(selectedGame.thumbnailFilename)
            let script = Runner.root.appending(
                path: "thumbnail-web/render-thumbnail.mjs"
            )
            let shell = URL(fileURLWithPath: "/bin/zsh")
            let displayDate = selectedGame.displayDate
            _ = try await Task.detached {
                try Runner.run(
                    shell,
                    arguments: [
                        "-ic", "exec node \"$@\"", "thumbnail-render",
                        script.path, background.path, selectedGame.home,
                        selectedGame.away, displayDate, output.path,
                    ]
                )
            }.value
            guard FileManager.default.fileExists(atPath: output.path) else {
                throw Runner.RunError.missingOutput(output.path)
            }
            scene = .done
            message = "Thumbnail saved to \(output.path)."
        } catch { message = error.localizedDescription }
    }
}

struct ContentView: View {
    @State private var workflow = Workflow()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Unified App").font(.largeTitle.bold())
                Spacer()
                if let version = Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Divider()
            switch workflow.scene {
            case .games:
                HStack {
                    Text("Page")
                    TextField("Page number", text: $workflow.page).frame(
                        width: 90
                    )
                    Button("Query") { Task { await workflow.query() } }
                        .disabled(workflow.busy)
                }
                List(workflow.games) { game in
                    Button {
                        Task { await workflow.select(game) }
                    } label: {
                        HStack {
                            Text(game.date).frame(
                                width: 110,
                                alignment: .leading
                            )
                            Text(game.teams)
                            Spacer()
                            Text(game.id).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            case .attempts, .mapper, .editor:
                if workflow.busy {
                    ProgressView(
                        workflow.scene == .attempts
                            ? "Fetching attempts…"
                            : workflow.scene == .mapper
                                ? "Waiting for TheMapper…"
                                : "Waiting for ClipEditor…"
                    )
                } else if workflow.scene == .attempts,
                    let game = workflow.selectedGame
                {
                    Button("Retry fetching attempts") {
                        Task { await workflow.select(game) }
                    }
                    Button("Back to games") { workflow.scene = .games }
                } else if workflow.scene == .mapper {
                    Button("Retry TheMapper") {
                        Task { await workflow.runMapper() }
                    }
                }
                Spacer()
            case .video:
                Button("Choose Video…") { workflow.chooseVideo() }
                Spacer()
            case .thumbnail:
                if let videoURL = workflow.videoURL {
                    ThumbnailSelectionView(
                        videoURL: videoURL,
                        busy: workflow.busy
                    ) { selection, time in
                        Task {
                            await workflow.generateThumbnail(
                                selection: selection,
                                time: time
                            )
                        }
                    }
                }
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

private struct ThumbnailSelectionView: View {
    let videoURL: URL
    let busy: Bool
    let generate: (CGRect, Double) -> Void
    @State private var player = AVPlayer()
    @State private var selection: CGRect?
    @State private var currentTime = 0.0
    @State private var duration = 1.0
    @State private var playing = false
    @State private var seeking = false
    @State private var zoom = 1.0
    @State private var windowStart = 0.0

    private var windowLength: Double { max(duration / zoom, 0.01) }
    private var windowEnd: Double { min(windowStart + windowLength, duration) }

    private func centerWindow(on time: Double) {
        windowStart = min(max(time - windowLength / 2, 0), max(duration - windowLength, 0))
    }

    private func moveWindow(_ direction: Double) {
        windowStart = min(max(windowStart + direction * windowLength * 0.8, 0), max(duration - windowLength, 0))
        currentTime = min(max(currentTime, windowStart), windowEnd)
        seek(to: currentTime)
    }

    private func seek(to time: Double) {
        seeking = true
        player.seek(
            to: CMTime(seconds: time, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { finished in
            if finished {
                DispatchQueue.main.async {
                    currentTime = player.currentTime().seconds
                    seeking = false
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Thumbnail Generation").font(.title2.bold())
            Text(
                "Play or scrub to a frame, then drag one rectangle over the video. Drag again to replace it."
            )
            ThumbnailRegionView(player: player, selection: $selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Button(playing ? "Pause" : "Play") {
                    if playing {
                        player.pause()
                        currentTime = player.currentTime().seconds
                    } else { player.play() }
                }
                Slider(
                    value: Binding(
                        get: { currentTime },
                        set: { time in
                            currentTime = time
                            seek(to: time)
                        }
                    ),
                    in: windowStart...max(windowEnd, windowStart + 0.01)
                ) { editing in
                    if editing { player.pause() }
                }
                Text(String(format: "%.1f / %.1f s", currentTime, duration))
                    .monospacedDigit()
            }
            HStack {
                Button("Earlier") { moveWindow(-1) }
                    .disabled(zoom == 1 || windowStart == 0)
                Slider(value: $zoom, in: 1...128)
                    .onChange(of: zoom) { centerWindow(on: currentTime) }
                Text(String(format: "%.0f× zoom", zoom))
                    .frame(width: 90, alignment: .trailing)
                Button("Later") { moveWindow(1) }
                    .disabled(zoom == 1 || windowEnd >= duration)
                Text(String(format: "%.1f–%.1f s", windowStart, windowEnd))
                    .monospacedDigit()
                    .frame(width: 150, alignment: .trailing)
            }
            Button(busy ? "Generating…" : "Generate Thumbnail") {
                if let selection { generate(selection, player.currentTime().seconds) }
            }
            .disabled(selection == nil || busy || seeking)
        }
        .task {
            let asset = AVURLAsset(url: videoURL)
            duration = (try? await asset.load(.duration).seconds) ?? 1
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        }
        .onReceive(
            Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()
        ) { _ in
            playing = player.rate != 0
            if playing {
                currentTime = player.currentTime().seconds
                if currentTime > windowEnd { centerWindow(on: currentTime) }
            }
        }
        .onDisappear {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
    }
}

private struct ThumbnailRegionView: NSViewRepresentable {
    let player: AVPlayer
    @Binding var selection: CGRect?

    func makeNSView(context: Context) -> ThumbnailRegionNSView {
        let view = ThumbnailRegionNSView()
        view.playerLayer.player = player
        view.onChange = { context.coordinator.selection.wrappedValue = $0 }
        return view
    }
    func updateNSView(_ view: ThumbnailRegionNSView, context: Context) {
        context.coordinator.selection = $selection
        view.playerLayer.player = player
        view.selection = selection
        view.onChange = { context.coordinator.selection.wrappedValue = $0 }
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    final class Coordinator {
        var selection: Binding<CGRect?>
        init(selection: Binding<CGRect?>) { self.selection = selection }
    }
}

private final class ThumbnailRegionNSView: NSView {
    let playerLayer = AVPlayerLayer()
    private let outline = CAShapeLayer()
    var selection: CGRect? { didSet { drawOutline() } }
    var onChange: ((CGRect?) -> Void)?
    private var start: CGPoint?
    override var isFlipped: Bool { true }
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        outline.strokeColor = NSColor.systemYellow.cgColor
        outline.fillColor =
            NSColor.systemYellow.withAlphaComponent(0.15).cgColor
        outline.lineWidth = 2
        layer?.addSublayer(outline)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        outline.frame = bounds
        drawOutline()
    }
    private func drawOutline() {
        guard let selection else {
            outline.path = nil
            return
        }
        let video = playerLayer.videoRect
        outline.path = CGPath(
            rect: CGRect(
                x: video.minX + selection.minX * video.width,
                y: video.minY + selection.minY * video.height,
                width: selection.width * video.width,
                height: selection.height * video.height
            ),
            transform: nil
        )
    }
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let video = playerLayer.videoRect
        return CGPoint(
            x: min(max(p.x, video.minX), video.maxX),
            y: min(max(p.y, video.minY), video.maxY)
        )
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard playerLayer.videoRect.contains(p) else { return }
        start = point(event)
        selection = nil
        onChange?(nil)
    }
    override func mouseDragged(with event: NSEvent) {
        update(event, finished: false)
    }
    override func mouseUp(with event: NSEvent) {
        update(event, finished: true)
        start = nil
    }
    private func update(_ event: NSEvent, finished: Bool) {
        guard let start else { return }
        let end = point(event)
        let video = playerLayer.videoRect
        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(start.x - end.x),
            height: abs(start.y - end.y)
        )
        selection =
            finished && (rect.width < 4 || rect.height < 4)
            ? nil
            : CGRect(
                x: (rect.minX - video.minX) / video.width,
                y: (rect.minY - video.minY) / video.height,
                width: rect.width / video.width,
                height: rect.height / video.height
            )
        onChange?(selection)
    }
}
