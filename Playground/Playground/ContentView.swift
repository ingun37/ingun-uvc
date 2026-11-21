import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct ContentView: View {
    @State private var showingFilePicker = false
    @State private var videoURL: URL?
    @State private var duration = 0.0
    @State private var selectedTime = 0.0
    @State private var originalFrame: CGImage?
    @State private var frame: CGImage?
    @State private var noiseReductionEnabled = false
    @State private var noiseLevel = 0.02
    @State private var sharpness = 0.4
    @State private var masks: [PlayerMask] = []
    @State private var isLoadingVideo = false
    @State private var isLoadingFrame = false
    @State private var isProcessingFrame = false
    @State private var isDetecting = false
    @State private var errorMessage: String?
    @State private var videoLoadTask: Task<Void, Never>?
    @State private var frameTask: Task<Void, Never>?
    @State private var processingTask: Task<Void, Never>?
    @State private var detectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Button("Choose Video…") { showingFilePicker = true }
                if let videoURL {
                    Text(videoURL.lastPathComponent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.black)
                if let frame {
                    Image(decorative: frame, scale: 1)
                        .resizable()
                        .scaledToFit()
                } else if isLoadingVideo || isLoadingFrame {
                    ProgressView(isLoadingVideo ? "Loading video…" : "Loading frame…")
                        .foregroundStyle(.white)
                } else {
                    ContentUnavailableView("Choose a Video", systemImage: "video")
                }
                if (isLoadingFrame || isProcessingFrame) && frame != nil {
                    ProgressView()
                        .padding(8)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(8)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 360)

            HStack {
                Text(timeLabel(selectedTime))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .leading)
                Slider(value: $selectedTime, in: 0...max(duration, 0.001))
                    .disabled(videoURL == nil || duration <= 0)
                    .onChange(of: selectedTime) { _, _ in loadFrame() }
                Text(timeLabel(duration))
                    .monospacedDigit()
                    .frame(width: 64, alignment: .trailing)
            }

            GroupBox("Noise Reduction") {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Apply to preview and detection", isOn: $noiseReductionEnabled)
                        .onChange(of: noiseReductionEnabled) { _, _ in processFrame() }
                    HStack {
                        Text("Amount")
                            .frame(width: 78, alignment: .leading)
                        Slider(value: $noiseLevel, in: 0...0.2, step: 0.005)
                            .onChange(of: noiseLevel) { _, _ in processFrame() }
                        Text(noiseLevel.formatted(.number.precision(.fractionLength(3))))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    HStack {
                        Text("Sharpness")
                            .frame(width: 78, alignment: .leading)
                        Slider(value: $sharpness, in: 0...1, step: 0.05)
                            .onChange(of: sharpness) { _, _ in processFrame() }
                        Text(sharpness.formatted(.number.precision(.fractionLength(2))))
                            .monospacedDigit()
                            .frame(width: 48, alignment: .trailing)
                    }
                    Button("Reset Parameters") {
                        noiseLevel = 0.02
                        sharpness = 0.4
                    }
                }
            }

            HStack {
                Button("Detect Players") { detectPlayers() }
                    .disabled(frame == nil || isLoadingFrame || isProcessingFrame || isDetecting)
                if isDetecting { ProgressView() }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if !masks.isEmpty {
                Text("Player Masks (\(masks.count))")
                    .font(.headline)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(masks) { mask in
                            VStack {
                                Image(decorative: mask.image, scale: 1)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 180, height: 130)
                                    .background(.black)
                                Text("Player \(mask.number)")
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 550)
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.movie]) { result in
            switch result { 
            case .success(let url): openVideo(url)
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .onDisappear {
            videoLoadTask?.cancel()
            frameTask?.cancel()
            processingTask?.cancel()
            detectionTask?.cancel()
            videoURL?.stopAccessingSecurityScopedResource()
        }
    }

    private func openVideo(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "The selected video could not be accessed."
            return
        }
        videoLoadTask?.cancel()
        frameTask?.cancel()
        processingTask?.cancel()
        detectionTask?.cancel()
        videoURL?.stopAccessingSecurityScopedResource()
        videoURL = url
        duration = 0
        selectedTime = 0
        originalFrame = nil
        frame = nil
        masks = []
        errorMessage = nil
        isDetecting = false
        isLoadingVideo = true
        isLoadingFrame = false
        isProcessingFrame = false

        videoLoadTask = Task {
            do {
                let asset = AVURLAsset(url: url)
                let loadedDuration = try await asset.load(.duration)
                guard !Task.isCancelled else { return }
                let seconds = CMTimeGetSeconds(loadedDuration)
                guard seconds.isFinite, seconds > 0 else {
                    throw VideoError.invalidDuration
                }
                duration = seconds
                isLoadingVideo = false
                loadFrame()
            } catch {
                guard !Task.isCancelled else { return }
                isLoadingVideo = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func loadFrame() {
        guard let videoURL, duration > 0 else { return }
        frameTask?.cancel()
        processingTask?.cancel()
        detectionTask?.cancel()
        masks = []
        isDetecting = false
        isLoadingFrame = true
        isProcessingFrame = false
        errorMessage = nil
        let time = frameTime

        frameTask = Task {
            do {
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
                generator.appliesPreferredTrackTransform = true
                let image = try await generator.image(
                    at: CMTime(seconds: time, preferredTimescale: 600)
                ).image
                guard !Task.isCancelled else { return }
                originalFrame = image
                isLoadingFrame = false
                processFrame()
            } catch {
                guard !Task.isCancelled else { return }
                originalFrame = nil
                frame = nil
                isLoadingFrame = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func processFrame() {
        processingTask?.cancel()
        detectionTask?.cancel()
        masks = []
        isDetecting = false
        guard let originalFrame, !isLoadingFrame else { return }
        errorMessage = nil

        guard noiseReductionEnabled else {
            frame = originalFrame
            isProcessingFrame = false
            return
        }

        isProcessingFrame = true
        let noiseLevel = Float(noiseLevel)
        let sharpness = Float(sharpness)
        processingTask = Task {
            do {
                let processed = try await Task.detached(priority: .userInitiated) {
                    let input = CIImage(cgImage: originalFrame)
                    let filter = CIFilter.noiseReduction()
                    filter.inputImage = input
                    filter.noiseLevel = noiseLevel
                    filter.sharpness = sharpness
                    guard let output = filter.outputImage,
                          let image = CIContext().createCGImage(output, from: input.extent) else {
                        throw VideoError.filterRenderingFailed
                    }
                    return image
                }.value
                guard !Task.isCancelled else { return }
                frame = processed
                isProcessingFrame = false
            } catch {
                guard !Task.isCancelled else { return }
                frame = nil
                isProcessingFrame = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func detectPlayers() {
        guard let frame, !isLoadingFrame, !isProcessingFrame else { return }
        detectionTask?.cancel()
        masks = []
        errorMessage = nil
        isDetecting = true

        detectionTask = Task {
            do {
                let detected = try await Task.detached(priority: .userInitiated) {
                    let request = VNGeneratePersonInstanceMaskRequest()
                    let handler = VNImageRequestHandler(cgImage: frame)
                    try handler.perform([request])
                    guard let observation = request.results?.first else { return [PlayerMask]() }
                    let context = CIContext()
                    return try observation.allInstances.enumerated().map { offset, instance in
                        let buffer = try observation.generateScaledMaskForImage(
                            forInstances: IndexSet(integer: instance),
                            from: handler
                        )
                        let image = CIImage(cvPixelBuffer: buffer)
                        guard let cgImage = context.createCGImage(image, from: image.extent) else {
                            throw VideoError.maskRenderingFailed
                        }
                        return PlayerMask(number: offset + 1, image: cgImage)
                    }
                }.value
                guard !Task.isCancelled else { return }
                masks = detected
                isDetecting = false
                if detected.isEmpty { errorMessage = "No players were detected in this frame." }
            } catch {
                guard !Task.isCancelled else { return }
                isDetecting = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private var frameTime: Double {
        min(selectedTime, max(0, duration - 1.0 / 600))
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let wholeSeconds = Int(seconds)
        return String(format: "%d:%02d", wholeSeconds / 60, wholeSeconds % 60)
    }
}

private struct PlayerMask: Identifiable {
    let number: Int
    let image: CGImage
    var id: Int { number }
}

private enum VideoError: LocalizedError {
    case invalidDuration
    case filterRenderingFailed
    case maskRenderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "This video has no readable duration."
        case .filterRenderingFailed: "Noise reduction could not be displayed."
        case .maskRenderingFailed: "A player mask could not be displayed."
        }
    }
}

#Preview {
    ContentView()
}
