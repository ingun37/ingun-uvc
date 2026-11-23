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
    case boxscore = "Final box score CSV (optional)"

    static let required: [Self] = [.video, .mapping, .attempts]

    var types: [UTType] {
        switch self {
        case .video: [.movie, .video]
        case .mapping: [.json]
        case .attempts, .boxscore: [.commaSeparatedText]
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
    var countEvents: [String: [CountEvent]] = [:]
    var boxScore: BoxScore?
    var gameDate: String?
    var message = ""
    var errorDetails: String?
    var isBusy = false
    var exportedURL: URL?
    var playerExportURLs: [URL] = []
    var exportedPlayerStats: [PlayerFieldGoalStats] = []
    var effectWarnings: [String] = []
    var shotEffectSettings: ShotEffectSettings = .defaults
    private var files: [InputKind: FileAccess] = [:]

    var videoURL: URL? { files[.video]?.url }
    var canContinue: Bool { InputKind.required.allSatisfy { files[$0] != nil } && !isBusy }
    var selectedClips: [Clip] { clips.filter(\.included) }
    var missingLocationCount: Int {
        selectedClips.flatMap(\.captions).filter { $0.location == nil }.count
    }
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
        countEvents = [:]
        boxScore = nil
        exportedURL = nil
        playerExportURLs = []
        exportedPlayerStats = []
        effectWarnings = []
        message = ""
        errorDetails = nil
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
            countEvents = try ClipPlanner.countEvents(from: csv)
            boxScore = try files[.boxscore].map {
                try BoxScore(csv: String(contentsOf: $0.url, encoding: .utf8))
            }
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

    func export(to outputURL: URL? = nil, effects: [ShotEffectKey: AppliedShotEffect] = [:]) async {
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
        exportedURL = nil
        playerExportURLs = []
        exportedPlayerStats = []
        effectWarnings = []
        errorDetails = nil
        message = "Exporting compilation…"
        defer { isBusy = false; _ = access }
        var exportPhase = "prepare the compilation"
        do {
            var warnings: [String] = []
            var prepared: [ShotEffectKey: PreparedShotEffect] = [:]
            let fetchDateText = gameDate ?? destination.deletingPathExtension().lastPathComponent
                .components(separatedBy: " | ").last
            let date = PlayerAttemptFetcher.gameDate(fetchDateText)
            let courtSpots = Result { try CourtSpotMap.bundled() }
            var fetched: [String: Result<String, Error>] = [:]
            for clip in selectedClips {
                for index in clip.attempts.indices {
                    let key = ShotEffectKey(clipID: clip.id, attemptIndex: index)
                    guard let effect = effects[key] else { continue }
                    let label = "\(effect.playerName), attempt \(index + 1)"
                    guard effect.timestamp >= clip.start, effect.timestamp < clip.end else {
                        warnings.append("\(label): saved release frame is outside the edited clip")
                        continue
                    }
                    guard let playerID = effect.playerID, !playerID.isEmpty else {
                        warnings.append("\(label): \(ShotEffectError.missingPlayerID.localizedDescription)")
                        continue
                    }
                    guard let date else {
                        warnings.append("\(label): \(ShotEffectError.missingDate.localizedDescription)")
                        continue
                    }
                    if fetched[playerID] == nil {
                        message = "Fetching past-year attempts for \(effect.playerName)…"
                        do {
                            let csv = try await PlayerAttemptFetcher.fetch(playerID: playerID, gameDate: date)
                            fetched[playerID] = .success(csv)
                            do {
                                _ = try PlayerAttemptFetcher.saveCopy(csv, shortName: effect.playerName,
                                                                     playerID: playerID, beside: video)
                            } catch {
                                warnings.append("\(label): Could not save the past-year CSV beside the input video: \(error.localizedDescription)")
                                effectWarnings = warnings
                            }
                        } catch {
                            fetched[playerID] = .failure(error)
                        }
                    }
                    do {
                        let csv = try fetched[playerID]!.get()
                        guard let location = effect.shotLocation else {
                            throw ShotEffectError.missingShotLocation
                        }
                        let mapping = try courtSpots.get()
                        guard let spotIndex = mapping.nearestSpotIndex(to: location),
                              let spotLabel = mapping.label(at: spotIndex) else {
                            throw ShotEffectError.missingCourtSpot
                        }
                        let stats = try LocalShotStats.atSpot(spotIndex, in: csv, mapping: mapping)
                        guard stats.hasEnoughSamplesForEffect else {
                            let detail = "\(label) at \(String(format: "%.3f", effect.timestamp))s " +
                                "(\(effect.shotDescription)): \(stats.attempts) past-year attempts " +
                                "at \(spotLabel); at least \(LocalShotStats.minimumSamplesForEffect) required"
                            print("[ClipEditor] Skipped shot effect: \(detail)")
                            warnings.append(detail)
                            effectWarnings = warnings
                            continue
                        }
                        prepared[key] = PreparedShotEffect(effect: effect, stats: stats,
                                                           spotLabel: spotLabel)
                    } catch {
                        warnings.append("\(label): \(error.localizedDescription)")
                        effectWarnings = warnings
                    }
                }
            }
            effectWarnings = warnings
            let compilationCard = try boxScore.map {
                try BoxScoreVideo.render(CompilationBoxScoreView(boxScore: $0, date: gameDate))
            }
            let playerCards: [String: CGImage] = try boxScore.map { score in
                var cards: [String: CGImage] = [:]
                for group in groups {
                    guard let player = score.players.first(where: { $0.matches(group.key) }) else {
                        throw BoxScore.BoxScoreError.playerMissing(group.name)
                    }
                    cards[group.key] = try BoxScoreVideo.render(PlayerBoxScoreView(player: player))
                }
                return cards
            } ?? [:]
            exportPhase = "export the all-player compilation"
            message = "Exporting compilation…"
            try await VideoCompilation.export(videoURL: video, clips: selectedClips,
                                              destination: destination, endCard: compilationCard,
                                              shotEffects: prepared,
                                              shotEffectSettings: shotEffectSettings)
            var playerURLs: [URL] = []
            var usedNames: Set<String> = [destination.lastPathComponent.lowercased()]
            let compilationName = destination.deletingPathExtension().lastPathComponent
            let dateText = gameDate ?? compilationName.components(separatedBy: " | ").last.flatMap {
                $0 == compilationName ? nil : $0
            } ?? "Unknown date"
            let shortDate = dateText.components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? dateText
            for group in groups {
                for clip in group.clips {
                    for index in clip.attempts.indices where clip.attempts[index].player == group.key {
                        let key = ShotEffectKey(clipID: clip.id, attemptIndex: index)
                        guard let effect = prepared[key]?.effect,
                              !ShotEffectArea.fitsInsideCenteredSquare(effect.bounds,
                                                                      in: effect.frameSize) else { continue }
                        let detail = "\(group.name), attempt \(index + 1): per-player shot effect skipped because its bounding box crosses the square crop."
                        warnings.append(detail)
                        print("[ClipEditor] \(detail)")
                    }
                }
                effectWarnings = warnings
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
                exportPhase = "export \(group.name)'s video"
                message = "Exporting \(group.name)…"
                try await VideoCompilation.export(videoURL: video, clips: group.clips, destination: url,
                                                  title: group.name,
                                                  subtitle: "Every 🧱 VS \(opponent) | \(shortDate)",
                                                  player: group.key, square: true,
                                                  countEvents: countEvents[group.key] ?? [],
                                                  endCard: playerCards[group.key],
                                                  shotEffects: prepared,
                                                  shotEffectSettings: shotEffectSettings)
                playerURLs.append(url)
            }
            exportedURL = destination
            playerExportURLs = playerURLs
            exportedPlayerStats = PlayerFieldGoalStats.exportedPlayers(groups.map(\.key), countEvents: countEvents)
            message = "Saved compilation and \(playerURLs.count) player videos to \(destination.deletingLastPathComponent().path)."
            effectWarnings = warnings
        } catch {
            message = "Could not \(exportPhase)."
            errorDetails = Self.errorDetails(for: error)
        }
    }

    private static func errorDetails(for error: Error) -> String {
        var lines: [String] = []
        var current: NSError? = error as NSError
        var seen: Set<ObjectIdentifier> = []
        while let problem = current, seen.insert(ObjectIdentifier(problem)).inserted {
            lines.append("\(problem.localizedDescription) [\(problem.domain), code \(problem.code)]")
            if let reason = problem.localizedFailureReason, !reason.isEmpty,
               reason != problem.localizedDescription {
                lines.append("Reason: \(reason)")
            }
            if let suggestion = problem.localizedRecoverySuggestion, !suggestion.isEmpty {
                lines.append("Suggestion: \(suggestion)")
            }
            current = problem.userInfo[NSUnderlyingErrorKey] as? NSError
            if current != nil { lines.append("Caused by:") }
        }
        return lines.joined(separator: "\n")
    }
}

struct ContentView: View {
    @Environment(ShotEffectStore.self) private var shotEffects
    let videoURL: URL?
    let mappingURL: URL?
    let attemptsURL: URL?
    let boxscoreURL: URL?
    let outputURL: URL?
    let gameDate: String?
    private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    private let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    @State private var model = EditorModel()
    @State private var didLoadLaunchInputs = false
    @State private var dateInput = ""
    @State private var ellipseSizeInput = String(ShotEffectSettings.defaults.ellipseWidthMultiplier)
    @State private var effectDurationInput = String(ShotEffectSettings.defaults.duration)
    @State private var previewSpeed = 4.0
    @State private var selectedPreviewID: UUID?
    @State private var moveAllByClipID: [UUID: Bool] = [:]
    @State private var previewPlayToggle = 0
    @State private var previewKeyMonitor: Any?

    init(videoURL: URL? = nil, mappingURL: URL? = nil,
         attemptsURL: URL? = nil, boxscoreURL: URL? = nil,
         outputURL: URL? = nil, gameDate: String? = nil) {
        self.videoURL = videoURL
        self.mappingURL = mappingURL
        self.attemptsURL = attemptsURL
        self.boxscoreURL = boxscoreURL
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
            if let details = model.errorDetails {
                ScrollView {
                    Text(details)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 170)
                .accessibilityIdentifier("exportErrorDetails")
            }
            if !model.effectWarnings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Skipped special effects", systemImage: "exclamationmark.triangle.fill")
                    ScrollView {
                        Text(model.effectWarnings.joined(separator: "\n\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 170)
                }
                .foregroundStyle(.orange)
            }
            if model.exportedURL != nil, !model.exportedPlayerStats.isEmpty {
                exportRankings
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
                                (.attempts, attemptsURL), (.boxscore, boxscoreURL)] {
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
            if gameDate == nil {
                HStack {
                    Text("Game date").frame(width: 230, alignment: .leading)
                    TextField("Nov 16, 2026", text: $dateInput)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("gameDateInput")
                    Text("MMM d, yyyy")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(Color.gray.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                if !dateInput.isEmpty && PlayerAttemptFetcher.inputGameDate(dateInput) == nil {
                    Text("Enter the game date like Nov 16, 2026.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            HStack {
                Text("Ellipse size").frame(width: 230, alignment: .leading)
                TextField("Width multiplier", text: $ellipseSizeInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Text("× bounding box width")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Shot effect duration").frame(width: 230, alignment: .leading)
                TextField("Seconds", text: $effectDurationInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                Text("seconds")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if shotEffectSettingsInput == nil {
                Text("Use an ellipse size from 0.1 to 10 and a duration from 0.3 to 30 seconds.")
                    .font(.caption).foregroundStyle(.orange)
            }
            Spacer()
            HStack {
                Spacer()
                Button(model.isBusy ? "Reading files…" : "Next") {
                    guard let settings = shotEffectSettingsInput else { return }
                    model.shotEffectSettings = settings
                    if gameDate == nil {
                        model.gameDate = PlayerAttemptFetcher.inputGameDate(dateInput)
                    }
                    Task { await model.prepare() }
                }
                .disabled(!model.canContinue ||
                          shotEffectSettingsInput == nil ||
                          (gameDate == nil && PlayerAttemptFetcher.inputGameDate(dateInput) == nil))
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var shotEffectSettingsInput: ShotEffectSettings? {
        ShotEffectSettings.parse(ellipseSize: ellipseSizeInput, duration: effectDurationInput)
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
            if model.missingLocationCount > 0 {
                Label("\(model.missingLocationCount) included attempts have no shot location. Their captions will appear at the bottom center in the compilation and player videos.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Preview speed")
                Slider(value: $previewSpeed, in: 0.5...6)
                    .frame(maxWidth: 240)
                Text("\(previewSpeed, specifier: "%.1f")×")
                    .monospacedDigit()
                    .frame(width: 42, alignment: .trailing)
            }
            Text("↑/↓ Select preview · ←/→ Move selected clip 0.5s with Move All · Space Play/Pause")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach($model.clips) { $clip in
                            if let videoURL = model.videoURL {
                                ClipRow(clip: $clip, videoURL: videoURL, videoDuration: model.videoDuration,
                                        shotEffectSettings: model.shotEffectSettings,
                                        previewSpeed: previewSpeed, isSelected: selectedPreviewID == clip.id,
                                        playToggle: previewPlayToggle, moveAll: moveAllBinding(for: clip.id))
                                    .id(clip.id)
                            }
                        }
                    }
                }
                .onAppear {
                    selectedPreviewID = model.clips.first?.id
                    previewKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        guard event.window === NSApp.mainWindow,
                              NSApp.modalWindow == nil,
                              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty else {
                            return event
                        }
                        switch event.keyCode {
                        case 125, 126: // Down, up
                            guard !model.clips.isEmpty else { return nil }
                            let index = model.clips.firstIndex { $0.id == selectedPreviewID } ?? 0
                            let next = min(max(index + (event.keyCode == 125 ? 1 : -1), 0), model.clips.count - 1)
                            selectedPreviewID = model.clips[next].id
                            withAnimation { proxy.scrollTo(selectedPreviewID, anchor: .center) }
                            return nil
                        case 49: // Space
                            if selectedPreviewID != nil { previewPlayToggle += 1 }
                            return nil
                        case 123, 124: // Left, right
                            guard let selectedPreviewID,
                                  moveAllByClipID[selectedPreviewID, default: true],
                                  let index = model.clips.firstIndex(where: { $0.id == selectedPreviewID }) else {
                                return event
                            }
                            let clip = model.clips[index]
                            let first = clip.attempts.map(\.originalSourceTime).min() ?? clip.originalStart
                            let last = clip.attempts.map(\.originalSourceTime).max() ?? clip.originalEnd
                            let range = max(0, first - 15)...min(model.videoDuration, last + 15)
                            let offset = event.keyCode == 123 ? -0.5 : 0.5
                            model.clips[index].moveHandle(0, to: clip.start + offset, moveAll: true, in: range)
                            return nil
                        default:
                            return event
                        }
                    }
                }
                .onDisappear {
                    if let previewKeyMonitor {
                        NSEvent.removeMonitor(previewKeyMonitor)
                        self.previewKeyMonitor = nil
                    }
                }
            }
            HStack {
                Button("Back") { model.scene = .choose }
                Spacer()
                Button(outputURL == nil ? "Next" : (model.isBusy ? "Exporting…" : "Export")) {
                    if let outputURL {
                        Task { await model.export(to: outputURL, effects: shotEffects.effects) }
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
                    Task { await model.export(effects: shotEffects.effects) }
                }
                .disabled(model.isBusy)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var exportRankings: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Exported players · game field goal totals")
                .font(.headline)
            HStack(alignment: .top, spacing: 24) {
                rankingList("Most misses", stats: PlayerFieldGoalStats.byMisses(model.exportedPlayerStats)) { stats in
                    "\(stats.misses) misses"
                }
                rankingList("Lowest field goal percentage", stats: PlayerFieldGoalStats.byPercentage(model.exportedPlayerStats)) { stats in
                    String(format: "%.1f%% (%d/%d)", stats.percentage, stats.made, stats.attempted)
                }
            }
        }
    }

    private func rankingList(_ title: String, stats: [PlayerFieldGoalStats],
                             value: @escaping (PlayerFieldGoalStats) -> String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.bold())
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(stats.enumerated()), id: \.element.id) { index, player in
                        HStack {
                            Text("\(index + 1). \(player.name)")
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(value(player)).monospacedDigit()
                        }
                    }
                }
            }
            .frame(maxHeight: 150)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func moveAllBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { moveAllByClipID[id, default: true] },
            set: { moveAllByClipID[id] = $0 }
        )
    }
}

private struct ClipRow: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(ShotEffectStore.self) private var shotEffects
    @Binding var clip: Clip
    let videoURL: URL
    let videoDuration: Double
    let shotEffectSettings: ShotEffectSettings
    let previewSpeed: Double
    let isSelected: Bool
    let playToggle: Int
    @Binding var moveAll: Bool

    private var timelineRange: ClosedRange<Double> {
        let first = clip.attempts.map(\.originalSourceTime).min() ?? clip.originalStart
        let last = clip.attempts.map(\.originalSourceTime).max() ?? clip.originalEnd
        return max(0, first - 15)...min(videoDuration, last + 15)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ClipPreview(url: videoURL, start: clip.start, end: clip.end, speed: previewSpeed,
                        isSelected: isSelected, playToggle: playToggle)
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
                Toggle("Move All", isOn: $moveAll)
                    .toggleStyle(.checkbox)
                ClipTimeline(clip: $clip, range: timelineRange, moveAll: moveAll)
                    .frame(height: 32)
                Text((["Start \(ClipPlanner.clockLabel(clip.start))"] +
                      clip.attempts.enumerated().map { "Attempt \($0.offset + 1) \(ClipPlanner.clockLabel($0.element.sourceTime))" } +
                      ["End \(ClipPlanner.clockLabel(clip.end))"]).joined(separator: " · "))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                HStack {
                    ForEach(clip.attempts.indices, id: \.self) { index in
                        let applied = shotEffects.effects[ShotEffectKey(clipID: clip.id, attemptIndex: index)] != nil
                        Button("Shot effect \(index + 1)\(applied ? " ✓" : "")") {
                            let attempt = clip.attempts[index]
                            openWindow(value: ShotEffectWindow(clipID: clip.id, attemptIndex: index,
                                                               videoURL: videoURL, clipStart: clip.start,
                                                               attemptTime: attempt.sourceTime,
                                                               playerID: attempt.playerID,
                                                               playerName: attempt.shortName ?? attempt.player?.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "Player",
                                                               shotDescription: attempt.shotDescription,
                                                               shotX: attempt.location.map { Double($0.x) },
                                                               shotY: attempt.location.map { Double($0.y) },
                                                               settings: shotEffectSettings))
                        }
                    }
                }
                Button("Reset timing") {
                    clip.resetTiming()
                }
                .disabled(clip.timingIsOriginal)
                Text("Drag the edges to change the clip and the middle handles to time attempts.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.gray.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct ClipTimeline: View {
    @Binding var clip: Clip
    let range: ClosedRange<Double>
    let moveAll: Bool

    private let handleSize = 16.0
    @State private var dragOrigin: (index: Int, time: Double)?

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - handleSize)
            let span = max(0.001, range.upperBound - range.lowerBound)
            let times = [clip.start] + clip.attempts.map(\.sourceTime) + [clip.end]
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.3))
                    .frame(height: 4)
                    .padding(.horizontal, handleSize / 2)
                Capsule()
                    .fill(Color.accentColor.opacity(0.45))
                    .frame(width: max(0, (clip.end - clip.start) / span * width), height: 4)
                    .offset(x: handleSize / 2 + (clip.start - range.lowerBound) / span * width)
                ForEach(times.indices, id: \.self) { index in
                    let time = times[index]
                    let isEdge = index == 0 || index == times.count - 1
                    RoundedRectangle(cornerRadius: isEdge ? 4 : 8)
                        .fill(isEdge ? Color.accentColor : Color.orange)
                        .frame(width: handleSize, height: isEdge ? 24 : 20)
                        .overlay(RoundedRectangle(cornerRadius: isEdge ? 4 : 8)
                            .strokeBorder(.white, lineWidth: 1))
                        .offset(x: (time - range.lowerBound) / span * width)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("clipTimeline"))
                            .onChanged { value in
                                if dragOrigin?.index != index { dragOrigin = (index, time) }
                                guard let dragOrigin else { return }
                                clip.moveHandle(index, to: dragOrigin.time + value.translation.width / width * span,
                                                moveAll: moveAll, in: range)
                            }
                            .onEnded { _ in dragOrigin = nil })
                        .accessibilityLabel(index == 0 ? "Start" : index == times.count - 1 ? "End" : "Attempt \(index)")
                        .accessibilityValue(ClipPlanner.clockLabel(time))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .leading)
            .coordinateSpace(name: "clipTimeline")
        }
    }
}

private struct ClipPreview: View {
    let url: URL
    let start: Double
    let end: Double
    let speed: Double
    let isSelected: Bool
    let playToggle: Int
    @State private var player = AVPlayer()

    var body: some View {
        NativePlayerView(player: player)
            .onAppear {
                player.defaultRate = Float(speed)
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                resetRange()
            }
            .onChange(of: speed) { _, newSpeed in
                player.defaultRate = Float(newSpeed)
                if player.timeControlStatus != .paused {
                    player.rate = Float(newSpeed)
                }
            }
            .onChange(of: isSelected) { _, selected in
                if !selected { player.pause() }
            }
            .onChange(of: playToggle) { _, _ in
                guard isSelected else { return }
                if player.timeControlStatus == .paused {
                    player.playImmediately(atRate: Float(speed))
                } else {
                    player.pause()
                }
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
