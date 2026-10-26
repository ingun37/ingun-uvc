import AppKit
import AVFoundation
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    private enum Stage { case fileSelect, videoPlay, process }
    @State private var stage = Stage.fileSelect
    @State private var session = VideoSession()
    @State private var didPresentPicker = false
    @State private var isPicking = false
    @State private var isScrubbing = false
    @State private var resumeAfterScrubbing = false
    @State private var isProcessing = false
    @State private var outputURL: URL?
    @State private var processingError: String?
    private let clock = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            switch stage {
            case .fileSelect: fileSelect
            case .videoPlay: videoPlay
            case .process: process
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .task {
            if !didPresentPicker {
                didPresentPicker = true
                chooseVideo()
            }
        }
        .onReceive(clock) { _ in
            if !isScrubbing { session.refreshPlayback() }
        }
        .onDisappear { session.close() }
        .alert("Unable to open video", isPresented: Binding(
            get: { session.errorMessage != nil },
            set: { if !$0 { session.errorMessage = nil } }
        )) {
            Button("OK") { session.errorMessage = nil }
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    private var fileSelect: some View {
        VStack(spacing: 18) {
            Image(systemName: "video").font(.system(size: 44)).foregroundStyle(.secondary)
            Text("File Select").font(.largeTitle)
            Text("Choose a video to play and select a region.").foregroundStyle(.secondary)
            if session.isLoading { ProgressView("Opening video…") }
            Button("Select Video…", action: chooseVideo)
                .buttonStyle(.borderedProminent)
                .disabled(isPicking || session.isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var videoPlay: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Video Play").font(.headline)
                    Text(session.url?.lastPathComponent ?? "").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Clear Rectangle") { session.region = nil }
                    .disabled(session.region == nil)
                Button("Done") {
                    session.pause()
                    stage = .process
                    startProcessing()
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.region?.isValid != true)
            }
            .padding()
            VideoCanvas(session: session)
            VStack(spacing: 10) {
                HStack(spacing: 12) {
                    Button(action: session.togglePlayback) {
                        Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 20)
                    }
                    .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                    Text(time(session.currentTime)).monospacedDigit()
                    Slider(value: Binding(get: { session.currentTime }, set: { session.seek(to: $0) }),
                           in: 0...max(session.duration, 0.01), onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            resumeAfterScrubbing = session.isPlaying
                            session.pause()
                        } else if resumeAfterScrubbing {
                            session.player.play()
                            session.isPlaying = true
                        }
                    })
                    .accessibilityLabel("Video position")
                    Text(time(session.duration)).monospacedDigit()
                }
                Text("Drag on the video to draw a rectangle. Drag again to replace it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private var process: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Process").font(.largeTitle)
            Text(session.url?.lastPathComponent ?? "").foregroundStyle(.secondary)
            if let region = session.region { RegionInformation(region: region) }
            if isProcessing {
                ProgressView("Reading game clocks…")
            } else if let outputURL {
                Label("Mapping saved", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(outputURL.path).textSelection(.enabled)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([outputURL])
                }
            } else if let processingError {
                Label("Processing failed", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                Text(processingError).textSelection(.enabled)
                Button("Try Again", action: startProcessing)
            }
            HStack {
                Button("Back to Video") { stage = .videoPlay }
                    .disabled(isProcessing)
                Button("Choose Another Video…") {
                    session.close()
                    stage = .fileSelect
                    chooseVideo()
                }
                .disabled(isProcessing)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func startProcessing() {
        guard !isProcessing, let videoURL = session.url,
              let region = session.decoderRegion() else {
            processingError = "Select a valid video region before processing."
            return
        }
        let base = videoURL.deletingPathExtension().lastPathComponent
        let folder = videoURL.deletingLastPathComponent()
        var candidate = folder.appendingPathComponent("\(base).gametime.json")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base).gametime-\(suffix).json")
            suffix += 1
        }
        let destination = candidate
        let videoPath = videoURL.path
        let outputPath = destination.path
        isProcessing = true
        processingError = nil
        outputURL = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) {
                TimeMapperBridge.mapVideo(atPath: videoPath, outputJSONPath: outputPath,
                                          x: region.x, y: region.y,
                                          width: region.width, height: region.height)
            }.value
            isProcessing = false
            if let failure {
                processingError = failure as String
            } else {
                outputURL = destination
            }
        }
    }

    private func chooseVideo() {
        guard !isPicking, !session.isLoading else { return }
        isPicking = true
        let panel = NSOpenPanel()
        panel.title = "Select a Video"
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            Task { @MainActor in
                isPicking = false
                guard response == .OK, let url = panel.url else { return }
                if await session.open(url) { stage = .videoPlay }
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

#Preview {
    ContentView()
}
