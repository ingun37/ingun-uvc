import AppKit
import AVFoundation
import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let outputURL: URL?
    let launchVideoURL: URL?

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    private enum Step { case choose, select, format, process }
    private struct ChartPoint: Identifiable {
        let id: Int
        let segment: Int
        let videoTime: Double
        let gameTime: Double
        let kind: VideoTimeMapper.Kind
    }
    private struct JSONEntry: Encodable {
        let period: String
        let game_start_seconds: Double
        let game_end_seconds: Double
        let video_start_seconds: Double
        let video_end_seconds: Double
    }

    @State private var step: Step = .choose
    @State private var videoURL: URL?
    @State private var hasSecurityScope = false
    @State private var player = AVPlayer()
    @State private var duration = 0.0
    @State private var naturalSize = CGSize(width: 1, height: 1)
    @State private var preferredTransform = CGAffineTransform.identity
    @State private var currentTime = 0.0
    @State private var isPlaying = false
    @State private var selectedRegion: CGRect?
    @State private var scoreboardFormat = GameTimeReader.ScoreboardFormat.Preset.a.format
    @State private var intervals: [VideoTimeMapper.Interval]?
    @State private var chartPoints: [ChartPoint] = []
    @State private var logLines: [String] = []
    @State private var processing = false
    @State private var errorMessage: String?
    @State private var savedURL: URL?
    @State private var didStart = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "timer").font(.title2).foregroundStyle(.tint)
                Text("The Mapper").font(.title2.bold())
                Spacer()
                if let savedURL { Text("Saved: \(savedURL.lastPathComponent)").foregroundStyle(.green) }
            }
            Divider()
            Group {
                switch step {
                case .choose: chooseView
                case .select: selectView
                case .format: formatView
                case .process: processView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                switch step {
                case .choose: EmptyView()
                case .select:
                    Button("Choose Another Video") { chooseVideo() }
                    Spacer()
                    Button("Next") { player.pause(); step = .format }
                        .keyboardShortcut(.defaultAction).disabled(selectedRegion == nil)
                case .format:
                    Button("Back to Selection") { step = .select }
                    Spacer()
                    Button("Start Processing") { beginProcessing() }.keyboardShortcut(.defaultAction)
                case .process:
                    Button("Back to Formats") { step = .format }.disabled(processing)
                    Spacer()
                    Button("Save JSON…") { saveMapping() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(processing || intervals == nil || (outputURL != nil && savedURL != nil))
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 570)
        .navigationTitle("The Mapper v\(bundleVersion)")
        .onAppear {
            guard !didStart else { return }
            didStart = true
            guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
            DispatchQueue.main.async {
                if let launchVideoURL { loadVideo(launchVideoURL) } else { chooseVideo() }
            }
        }
        .onReceive(Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()) { _ in
            guard step == .select else { return }
            currentTime = player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0
            isPlaying = player.rate != 0
        }
        .onDisappear {
            player.pause()
            if hasSecurityScope { videoURL?.stopAccessingSecurityScopedResource() }
        }
    }

    private var chooseView: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "film.stack").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("Choose a basketball game recording").font(.title3)
            Button("Choose Video…") { chooseVideo() }.controlSize(.large)
            Spacer()
        }
    }

    private var selectView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select the scoreboard").font(.title3.bold())
            Text("Play or scrub to a clear frame, then drag a rectangle around the scoreboard.")
                .foregroundStyle(.secondary)
            VideoRegionView(player: player, selection: $selectedRegion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Button { isPlaying ? player.pause() : player.play() } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                }
                Slider(value: Binding(get: { min(currentTime, duration) }, set: { value in
                    player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                    currentTime = value
                }), in: 0...max(duration, 0.01))
                Text(String(format: "%.1f / %.1f s", currentTime, duration))
                    .monospacedDigit().frame(width: 130)
            }
        }
    }

    private var formatView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Scoreboard text format").font(.title3.bold())
            Picker("Preset", selection: Binding(
                get: { scoreboardFormat.preset ?? .a },
                set: { scoreboardFormat = $0.format })) {
                ForEach(GameTimeReader.ScoreboardFormat.Preset.allCases) { preset in
                    Text(preset.rawValue).tag(preset)
                }
            }.frame(maxWidth: 500)
            ForEach(GameTimeReader.Period.allCases) { period in
                Picker(period.rawValue, selection: Binding(
                    get: { scoreboardFormat.periodStyles[period] ?? .short },
                    set: { scoreboardFormat.periodStyles[period] = $0 })) {
                    Text(period.shortLabel).tag(GameTimeReader.PeriodStyle.short)
                    Text(period.longLabel).tag(GameTimeReader.PeriodStyle.long)
                }.frame(maxWidth: 500)
            }
            Picker("Clock under a minute", selection: $scoreboardFormat.underMinuteStyle) {
                Text(":ss.s (e.g. :06.1)").tag(GameTimeReader.UnderMinuteStyle.colon)
                Text("ss.s or s.s (e.g. 16.1, 6.1)").tag(GameTimeReader.UnderMinuteStyle.natural)
                Text("ss.s (e.g. 16.1, 06.1)").tag(GameTimeReader.UnderMinuteStyle.doubleDigit)
            }.frame(maxWidth: 500)
            Spacer()
        }
    }

    private var processView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Process video").font(.title3.bold())
                Spacer()
                if processing { ProgressView().controlSize(.small) }
                else if let intervals { Text("Finished · \(intervals.count) intervals").foregroundStyle(.green) }
            }
            if !chartPoints.isEmpty {
                Chart(chartPoints) { point in
                    LineMark(x: .value("Video time", point.videoTime),
                             y: .value("Game time", point.gameTime),
                             series: .value("Interval", point.segment))
                        .foregroundStyle(point.kind == .paused ? .orange : .blue)
                }
                .chartXScale(domain: 0...max(duration, 1))
                .chartXAxisLabel("Video time (s)")
                .chartYAxisLabel("Game time remaining (s)")
                .frame(maxHeight: .infinity)
            } else {
                Text(processing ? "Reading frames and recognizing the game clock…" :
                     "No intervals found.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("Processing log").font(.subheadline.bold())
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(logLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 160)
            .padding(8)
            .background(.quaternary.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadVideo(url) }
    }

    private func loadVideo(_ url: URL) {
        if hasSecurityScope { videoURL?.stopAccessingSecurityScopedResource() }
        hasSecurityScope = url.startAccessingSecurityScopedResource()
        videoURL = url
        player = AVPlayer(url: url)
        selectedRegion = nil
        intervals = nil
        chartPoints = []
        errorMessage = nil
        savedURL = nil
        step = .select
        Task {
            do {
                let asset = AVURLAsset(url: url)
                duration = try await asset.load(.duration).seconds
                if let track = try await asset.loadTracks(withMediaType: .video).first {
                    naturalSize = try await track.load(.naturalSize)
                    preferredTransform = try await track.load(.preferredTransform)
                }
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func beginProcessing() {
        guard let videoURL, let selectedRegion else { return }
        // The frame generator already applies the track transform, so the selected
        // display rectangle only needs the top-left to bottom-left Y conversion.
        let region = CGRect(x: selectedRegion.minX, y: 1 - selectedRegion.maxY,
                            width: selectedRegion.width, height: selectedRegion.height)
        let format = scoreboardFormat
        processing = true
        step = .process
        intervals = nil
        chartPoints = []
        logLines = []
        errorMessage = nil
        savedURL = nil
        Task {
            do {
                let work = Task.detached {
                    try await VideoTimeMapper.map(videoURL: videoURL, format: format,
                        regionOfInterest: region, log: { line in
                            Task { @MainActor in logLines.append(line) }
                        })
                }
                let result = try await work.value
                intervals = result
                chartPoints = result.enumerated().flatMap { index, interval in
                    [ChartPoint(id: index * 2, segment: index, videoTime: interval.videoStart,
                                gameTime: interval.gameStart, kind: interval.kind),
                     ChartPoint(id: index * 2 + 1, segment: index, videoTime: interval.videoEnd,
                                gameTime: interval.gameEnd, kind: interval.kind)]
                }
            } catch { errorMessage = error.localizedDescription }
            processing = false
        }
    }

    private func saveMapping() {
        guard let intervals else { return }
        let destination: URL
        if let outputURL {
            destination = outputURL
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.directoryURL = videoURL?.deletingLastPathComponent()
            panel.nameFieldStringValue = (videoURL?.deletingPathExtension().lastPathComponent ?? "mapping") + ".json"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        do {
            let entries = intervals.map { interval in
                JSONEntry(period: interval.period,
                    game_start_seconds: interval.gameStart, game_end_seconds: interval.gameEnd,
                    video_start_seconds: interval.videoStart, video_end_seconds: interval.videoEnd)
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try (encoder.encode(entries) + Data([0x0a])).write(to: destination, options: .atomic)
            savedURL = destination
        } catch { errorMessage = error.localizedDescription }
    }
}
