import AppKit
import AVFoundation
import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Step: Int {
        case choose, select, process, save
    }

    private struct ChartSample: Identifiable {
        let id: Int
        let videoSecond: Double
        let gameSecond: Double
        let period: String
        let segment: Int
    }

    private enum ProcessEvent: Sendable {
        case sample(GameTimeMapper.Sample)
        case finished([GameTimeMapper.Entry])
        case failed(String)
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
    @State private var logLines: [String] = []
    @State private var chartSamples: [ChartSample] = []
    @State private var chartSegment = 0
    @State private var entries: [GameTimeMapper.Entry]?
    @State private var processing = false
    @State private var errorMessage: String?
    @State private var savedURL: URL?
    @State private var didPresentOpenPanel = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Game Time Mapper")
                    .font(.title2.bold())
                Spacer()
                Text("\(step.rawValue + 1) of 4")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Group {
                switch step {
                case .choose: chooseView
                case .select: selectView
                case .process: processView
                case .save: saveView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            HStack {
                if step == .select {
                    Button("Choose Another Video") { chooseVideo() }
                    Spacer()
                    Button("Next") { beginProcessing() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedRegion == nil)
                } else if step == .process {
                    if !processing {
                        Button("Back to Selection") { step = .select }
                    }
                    Spacer()
                    Button("Next") { showSavePanel() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(entries == nil || processing)
                } else if step == .save {
                    Button("Back to Log") { step = .process }
                    Spacer()
                    Button("Save JSON…") { showSavePanel() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 760, minHeight: 570)
        .onAppear {
            guard !didPresentOpenPanel else { return }
            didPresentOpenPanel = true
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                DispatchQueue.main.async { chooseVideo() }
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
            Image(systemName: "film.stack")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Choose a basketball game recording")
                .font(.title3)
            Button("Choose Video…") { chooseVideo() }
                .controlSize(.large)
            Spacer()
        }
    }

    private var selectView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select the scoreboard")
                .font(.title3.bold())
            Text("Play or scrub to a clear frame, then drag a tight rectangle around the scoreboard. Drag again to replace it.")
                .foregroundStyle(.secondary)
            VideoRegionView(player: player, selection: $selectedRegion)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 12) {
                Button {
                    if isPlaying { player.pause() } else { player.play() }
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                Slider(value: Binding(get: { min(currentTime, duration) }, set: { value in
                    player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                    currentTime = value
                }), in: 0...max(duration, 0.01))
                Text("\(formatTime(currentTime)) / \(formatTime(duration))")
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 120, alignment: .trailing)
            }
        }
    }

    private var processView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Process video")
                    .font(.title3.bold())
                Spacer()
                if processing { ProgressView().controlSize(.small) }
                else if let entries { Text("Finished · \(entries.count) ranges").foregroundStyle(.green) }
            }
            Text(processing ? "Reading frames and recognizing the game clock…" :
                    entries == nil ? "Processing stopped. Review the error below." : "Mapping complete. Review the log before continuing.")
                .foregroundStyle(.secondary)
            ZStack {
                Chart(chartSamples) { sample in
                    LineMark(x: .value("Video time", sample.videoSecond),
                             y: .value("Game time", sample.gameSecond),
                             series: .value("Segment", sample.segment))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("Video time", sample.videoSecond),
                              y: .value("Game time", sample.gameSecond))
                        .foregroundStyle(.blue)
                        .symbolSize(12)
                }
                .chartXScale(domain: 0...max(duration, 1))
                .chartXAxisLabel("Video time (s)")
                .chartYAxisLabel("Game time (s)")
                if chartSamples.isEmpty {
                    Text("Detected game clock readings will appear here")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 210)
            .padding(12)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text("Processing log")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(logLines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: logLines.count) { _, count in
                    if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                }
            }
            if !processing && entries == nil {
                Button("Try Again") { beginProcessing() }
            }
        }
    }

    private var saveView: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: savedURL == nil ? "curlybraces" : "checkmark.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(savedURL == nil ? Color.secondary : Color.green)
            Text(savedURL == nil ? "Save mapping JSON" : "Mapping saved")
                .font(.title3.bold())
            if let savedURL {
                Text(savedURL.path)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            } else {
                Text("Choose where to save the \(entries?.count ?? 0) mapped ranges.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a recording of a basketball game"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task {
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                    throw VideoError.noVideo
                }
                let seconds = try await asset.load(.duration).seconds
                guard seconds.isFinite, seconds > 0 else { throw VideoError.invalidDuration }
                let size = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                guard size.width > 0, size.height > 0 else { throw VideoError.invalidSize }
                player.pause()
                if hasSecurityScope { videoURL?.stopAccessingSecurityScopedResource() }
                videoURL = url
                hasSecurityScope = scoped
                player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
                duration = seconds
                naturalSize = size
                preferredTransform = transform
                currentTime = 0
                selectedRegion = nil
                entries = nil
                savedURL = nil
                logLines = []
                chartSamples = []
                chartSegment = 0
                errorMessage = nil
                step = .select
            } catch {
                if scoped { url.stopAccessingSecurityScopedResource() }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func beginProcessing() {
        guard let videoURL, let selectedRegion, !processing else { return }
        player.pause()
        step = .process
        processing = true
        entries = nil
        errorMessage = nil
        logLines = []
        chartSamples = []
        chartSegment = 0
        let visionRegion = VideoRegionGeometry.visionRegion(displaySelection: selectedRegion,
                                                           naturalSize: naturalSize,
                                                           preferredTransform: preferredTransform)
        let events = AsyncStream<ProcessEvent> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try await GameTimeMapper.map(
                        videoURL: videoURL, regionOfInterest: visionRegion,
                        onSample: { continuation.yield(.sample($0)) })
                    continuation.yield(.finished(result))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
        }
        Task {
            for await event in events {
                switch event {
                case .sample(let sample):
                    logLines.append(sample.logLine)
                    if let reading = sample.reading {
                        if let previous = chartSamples.last,
                           (previous.period != reading.period ||
                            sample.videoSecond - previous.videoSecond > 1.000001) {
                            chartSegment += 1
                        }
                        chartSamples.append(ChartSample(id: chartSamples.count,
                                                        videoSecond: sample.videoSecond,
                                                        gameSecond: reading.gameSecond,
                                                        period: reading.period,
                                                        segment: chartSegment))
                    } else {
                        chartSegment += 1
                    }
                case .finished(let result):
                    entries = result
                    processing = false
                case .failed(let message):
                    errorMessage = message
                    logLines.append("Error: \(message)")
                    processing = false
                }
            }
        }
    }

    private func showSavePanel() {
        guard let videoURL, let entries else { return }
        step = .save
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = videoURL.deletingLastPathComponent()
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".json"
        panel.message = "Save the game time mapping"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        do {
            try GameTimeMapper.save(entries, to: outputURL)
            savedURL = outputURL
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(max(0, seconds))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }

    private enum VideoError: LocalizedError {
        case noVideo, invalidDuration, invalidSize
        var errorDescription: String? {
            switch self {
            case .noVideo: "The selected file does not contain a video track."
            case .invalidDuration: "The selected video has an invalid duration."
            case .invalidSize: "The selected video has invalid dimensions."
            }
        }
    }
}
