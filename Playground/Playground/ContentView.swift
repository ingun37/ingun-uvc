import AVFoundation
import CoreImage
import SwiftUI
import UniformTypeIdentifiers
import Vision

struct ContentView: View {
    @State private var showingFilePicker = false
    @State private var videoURL: URL?
    @State private var duration = 0.0
    @State private var selectedTime = 0.0
    @State private var frame: CGImage?
    @State private var masks: [PlayerMask] = []
    @State private var isLoadingVideo = false
    @State private var isLoadingFrame = false
    @State private var isDetecting = false
    @State private var errorMessage: String?
    @State private var videoLoadTask: Task<Void, Never>?
    @State private var frameTask: Task<Void, Never>?
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
                if isLoadingFrame && frame != nil {
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

            HStack {
                Button("Detect Players") { detectPlayers() }
                    .disabled(frame == nil || isLoadingFrame || isDetecting)
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
        detectionTask?.cancel()
        videoURL?.stopAccessingSecurityScopedResource()
        videoURL = url
        duration = 0
        selectedTime = 0
        frame = nil
        masks = []
        errorMessage = nil
        isDetecting = false
        isLoadingVideo = true
        isLoadingFrame = false

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
        detectionTask?.cancel()
        masks = []
        isDetecting = false
        isLoadingFrame = true
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
                frame = image
                isLoadingFrame = false
            } catch {
                guard !Task.isCancelled else { return }
                frame = nil
                isLoadingFrame = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func detectPlayers() {
        guard let frame, !isLoadingFrame else { return }
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
    case maskRenderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidDuration: "This video has no readable duration."
        case .maskRenderingFailed: "A player mask could not be displayed."
        }
    }
}

#Preview {
    ContentView()
}
