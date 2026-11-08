import AppKit
import AVFoundation
import Charts
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    let outputURL: URL?
    let launchVideoURL: URL?

    private enum Step: Int {
        case choose, select, format, process, save
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
        case finished(GameTimeMapper.RawReadings)
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
    @State private var scoreboardFormat = GameTimeMapper.ScoreboardFormat.Preset.a.format
    @State private var logLines: [String] = []
    @State private var chartSamples: [ChartSample] = []
    @State private var hoveredSampleID: Int?
    @State private var hoverLocation: CGPoint?
    @State private var selectedSampleID: Int?
    @State private var rawReadings: GameTimeMapper.RawReadings?
    @State private var entries: [GameTimeMapper.Entry]?
    @State private var processing = false
    @State private var errorMessage: String?
    @State private var savedURL: URL?
    @State private var didPresentOpenPanel = false

    private var skipsVideoStep: Bool { launchVideoURL != nil && videoURL != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "timer")
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text("Game Time Mapper")
                    .font(.title2.bold())
                Spacer()
                Text("\(step.rawValue + 1 - (skipsVideoStep ? 1 : 0)) of \(5 - (outputURL == nil ? 0 : 1) - (skipsVideoStep ? 1 : 0))")
                    .foregroundStyle(.secondary)
            }

            Divider()

            Group {
                switch step {
                case .choose: chooseView
                case .select: selectView
                case .format: formatView
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
                    Button("Next") { player.pause(); step = .format }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selectedRegion == nil)
                } else if step == .format {
                    Button("Back to Selection") { step = .select }
                    Spacer()
                    Button("Start Processing") { beginProcessing() }
                        .keyboardShortcut(.defaultAction)
                } else if step == .process {
                    if !processing {
                        Button("Back to Formats") { step = .format }
                    }
                    Spacer()
                    Button(outputURL == nil ? "Next" : "Save JSON") { saveMapping() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(rawReadings == nil || processing || (outputURL != nil && savedURL != nil))
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
                DispatchQueue.main.async {
                    if let launchVideoURL {
                        loadVideo(launchVideoURL)
                    } else {
                        chooseVideo()
                    }
                }
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
                else if let rawReadings {
                    Text("Finished · \(rawReadings.samples.count) samples").foregroundStyle(.green)
                }
            }
            Text(processing ? "Reading frames and recognizing the game clock…" :
                    rawReadings == nil ? "Processing stopped. Review the error below." :
                    "Sampling complete. Review the readings before merging.")
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                Chart(chartSamples) { sample in
                    LineMark(x: .value("Video time", sample.videoSecond),
                             y: .value("Game time", sample.gameSecond),
                             series: .value("Segment", sample.segment))
                        .foregroundStyle(.blue)
                    PointMark(x: .value("Video time", sample.videoSecond),
                              y: .value("Game time", sample.gameSecond))
                        .foregroundStyle(sample.id == selectedSampleID ? .orange : .blue)
                        .symbolSize(sample.id == selectedSampleID ? 70 : 35)
                }
                .chartXScale(domain: 0...max(duration, 1))
                .chartXAxisLabel("Video time (s)")
                .chartYAxisLabel("Game time (s)")
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    hoveredSampleID = nearestSample(to: location, proxy: proxy,
                                                                    geometry: geometry)?.id
                                    hoverLocation = location
                                case .ended:
                                    hoveredSampleID = nil
                                    hoverLocation = nil
                                }
                            }
                            .gesture(SpatialTapGesture().onEnded { gesture in
                                guard !processing, rawReadings != nil else { return }
                                selectedSampleID = nearestSample(to: gesture.location,
                                                                 proxy: proxy, geometry: geometry)?.id
                            })
                        if let hoveredSampleID, let hoverLocation,
                           let hovered = chartSamples.first(where: { $0.id == hoveredSampleID }) {
                            Text("\(hovered.period) · \(formatGameTime(hovered.gameSecond))")
                                .font(.caption.monospacedDigit())
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                .position(x: min(max(hoverLocation.x, 60), geometry.size.width - 60),
                                          y: max(hoverLocation.y - 25, 15))
                                .allowsHitTesting(false)
                        }
                    }
                }
                if chartSamples.isEmpty {
                    Text(processing ? "Graph will appear when processing finishes" :
                         "No game clock readings to display")
                        .foregroundStyle(.secondary)
                }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 250)
                .padding(12)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                sampleDetail
                    .frame(width: 240, height: 274)
            }
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
            if !processing && rawReadings == nil {
                Button("Try Again") { beginProcessing() }
            }
            if outputURL != nil, let savedURL {
                Label("Mapping saved to \(savedURL.path)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
            }
        }
    }

    private var formatView: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scoreboard text formats")
                .font(.title3.bold())
            Text("Choose the text shown by this scoreboard. Each component uses one format throughout the game.")
                .foregroundStyle(.secondary)
            Picker("Preset", selection: Binding(
                get: { scoreboardFormat.preset?.rawValue ?? "custom" },
                set: { value in
                    if let preset = GameTimeMapper.ScoreboardFormat.Preset(rawValue: value) {
                        scoreboardFormat = preset.format
                    }
                })) {
                    ForEach(GameTimeMapper.ScoreboardFormat.Preset.allCases) { preset in
                        Text(preset.rawValue).tag(preset.rawValue)
                    }
                    if scoreboardFormat.preset == nil { Text("Custom").tag("custom") }
                }
                .frame(maxWidth: 360, alignment: .leading)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(GameTimeMapper.Period.allCases) { period in
                        Picker(period.rawValue, selection: Binding(
                            get: { scoreboardFormat.periodStyles[period] ?? .short },
                            set: { scoreboardFormat.periodStyles[period] = $0 })) {
                                Text(period.shortLabel).tag(GameTimeMapper.PeriodStyle.short)
                                Text(period.longLabel).tag(GameTimeMapper.PeriodStyle.long)
                            }
                            .frame(maxWidth: 480)
                    }
                    Picker("Clock over a minute", selection: .constant("minutes")) {
                        Text("mm:ss or m:ss").tag("minutes")
                    }
                    .disabled(true)
                    .frame(maxWidth: 480)
                    Picker("Clock under a minute", selection: $scoreboardFormat.underMinuteStyle) {
                        Text(":ss.s (e.g. :06.1)").tag(GameTimeMapper.UnderMinuteStyle.colon)
                        Text("ss.s or s.s (e.g. 16.1, 6.1)").tag(GameTimeMapper.UnderMinuteStyle.natural)
                    }
                    .frame(maxWidth: 480)
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var sampleDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let rawReadings, let selectedSampleID,
               let index = rawReadings.samples.firstIndex(where: { $0.id == selectedSampleID }),
               let reading = rawReadings.samples[index].reading {
                let sample = rawReadings.samples[index]
                Text("Sample details").font(.headline)
                Text("Video: \(String(format: "%.1f", sample.videoSecond)) s")
                Text("Game: \(reading.period) \(formatGameTime(reading.gameSecond))")
                if let previous = rawReadings.samples[..<index].last(where: { $0.reading != nil }),
                   let previousReading = previous.reading {
                    Text("Previous: \(previousReading.period) \(formatGameTime(previousReading.gameSecond))")
                    Text(changeDescription(reading.gameSecond - previousReading.gameSecond))
                } else {
                    Text("No previous clock reading")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Text("OCR readings").font(.subheadline.bold())
                ScrollView {
                    if sample.ocrTexts.isEmpty {
                        Text("No text recognized")
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(sample.ocrTexts.enumerated()), id: \.offset) { _, text in
                                Text(text)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                Button("Remove Sample", role: .destructive) {
                    let filtered = rawReadings.removingSample(id: selectedSampleID)
                    self.rawReadings = filtered
                    chartSamples = chartSamplesFor(filtered.samples)
                    self.selectedSampleID = nil
                    hoveredSampleID = nil
                    entries = nil
                }
                .disabled(processing)
            } else {
                Text("Sample details").font(.headline)
                Text("Click a point to inspect its OCR readings and remove an incorrect sample.")
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func nearestSample(to location: CGPoint, proxy: ChartProxy,
                               geometry: GeometryProxy) -> ChartSample? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let origin = geometry[plotFrame].origin
        return chartSamples.compactMap { sample -> (ChartSample, CGFloat)? in
            guard let x = proxy.position(forX: sample.videoSecond),
                  let y = proxy.position(forY: sample.gameSecond) else { return nil }
            let distance = hypot(location.x - origin.x - x, location.y - origin.y - y)
            return distance <= 18 ? (sample, distance) : nil
        }.min(by: { $0.1 < $1.1 })?.0
    }

    private func chartSamplesFor(_ samples: [GameTimeMapper.Sample]) -> [ChartSample] {
        var result: [ChartSample] = []
        var segment = 0
        for sample in samples {
            guard let reading = sample.reading else {
                segment += 1
                continue
            }
            if let previous = result.last,
               (previous.period != reading.period || sample.videoSecond - previous.videoSecond > 1.000001) {
                segment += 1
            }
            result.append(ChartSample(id: sample.id, videoSecond: sample.videoSecond,
                                      gameSecond: reading.gameSecond, period: reading.period,
                                      segment: segment))
        }
        return result
    }

    private func changeDescription(_ change: Double) -> String {
        if abs(change) < 0.000001 { return "Game time unchanged" }
        return String(format: "Game time %@ by %.1f s", change > 0 ? "increased" : "decreased", abs(change))
    }

    private func formatGameTime(_ seconds: Double) -> String {
        let minutes = Int(seconds / 60)
        let remainder = seconds - Double(minutes * 60)
        if remainder == remainder.rounded() {
            return String(format: "%d:%02d", minutes, Int(remainder))
        }
        return String(format: "%d:%04.1f", minutes, remainder)
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
        loadVideo(url)
    }

    private func loadVideo(_ url: URL) {
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
                scoreboardFormat = GameTimeMapper.ScoreboardFormat.Preset.a.format
                rawReadings = nil
                entries = nil
                savedURL = nil
                logLines = []
                chartSamples = []
                selectedSampleID = nil
                hoveredSampleID = nil
                hoverLocation = nil
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
        rawReadings = nil
        entries = nil
        savedURL = nil
        errorMessage = nil
        logLines = []
        chartSamples = []
        selectedSampleID = nil
        hoveredSampleID = nil
        hoverLocation = nil
        let visionRegion = VideoRegionGeometry.visionRegion(displaySelection: selectedRegion,
                                                           naturalSize: naturalSize,
                                                           preferredTransform: preferredTransform)
        let format = scoreboardFormat
        let events = AsyncStream<ProcessEvent> { continuation in
            Task.detached(priority: .userInitiated) {
                do {
                    let result = try await GameTimeMapper.sample(
                        videoURL: videoURL, regionOfInterest: visionRegion, format: format,
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
                case .finished(let result):
                    rawReadings = result
                    chartSamples = chartSamplesFor(result.samples)
                    processing = false
                case .failed(let message):
                    errorMessage = message
                    logLines.append("Error: \(message)")
                    processing = false
                }
            }
        }
    }

    private func saveMapping() {
        guard let videoURL, let rawReadings else { return }
        let merged = GameTimeMapper.merge(rawReadings)
        entries = merged
        if let outputURL {
            save(merged, to: outputURL)
            return
        }
        showSavePanel(videoURL: videoURL, entries: merged)
    }

    private func showSavePanel() {
        guard let videoURL, let entries else { return }
        showSavePanel(videoURL: videoURL, entries: entries)
    }

    private func showSavePanel(videoURL: URL, entries: [GameTimeMapper.Entry]) {
        step = .save
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.directoryURL = videoURL.deletingLastPathComponent()
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".json"
        panel.message = "Save the game time mapping"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        save(entries, to: outputURL)
    }

    private func save(_ entries: [GameTimeMapper.Entry], to outputURL: URL) {
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
