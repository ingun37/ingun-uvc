import AVFoundation
import Foundation
import AppKit
import QuartzCore

struct VideoCompilation {
    static func export(videoURL: URL, clips: [Clip], destination: URL) async throws {
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        let asset = AVURLAsset(url: videoURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw CompilationError.noVideo
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        let selected = clips.filter(\.included)
        guard !selected.isEmpty else { throw CompilationError.noClips }

        let composition = AVMutableComposition()
        guard let outputVideo = composition.addMutableTrack(withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CompilationError.trackSetup }
        outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        let outputAudio = audioTrack.map { _ in (0..<2).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }} ?? []
        if audioTrack != nil && outputAudio.count != 2 { throw CompilationError.trackSetup }
        let audioParameters = outputAudio.map { AVMutableAudioMixInputParameters(track: $0) }
        var cursor = CMTime.zero
        var overlays: [(Double, ShotCaption)] = []
        for (index, clip) in selected.enumerated() {
            let range = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600),
                                    end: CMTime(seconds: clip.end, preferredTimescale: 600))
            try outputVideo.insertTimeRange(range, of: videoTrack, at: cursor)
            overlays += clip.captions.filter { $0.sourceTime >= clip.start && $0.sourceTime < clip.end }
                .map { (cursor.seconds + $0.sourceTime - clip.start, $0) }
            if let audioTrack {
                // Audio extends across the video cut. Alternating tracks allow tails and heads to overlap.
                let head = index == 0 ? 0 : min(0.25, clip.start, selected[index - 1].end - selected[index - 1].start)
                let tail = index == selected.count - 1 ? 0 : min(0.25, duration - clip.end, selected[index + 1].end - selected[index + 1].start)
                let audioStart = max(0, clip.start - head)
                let audioEnd = min(duration, clip.end + tail)
                let audioAt = cursor - CMTime(seconds: clip.start - audioStart, preferredTimescale: 600)
                try outputAudio[index % 2].insertTimeRange(
                    CMTimeRange(start: CMTime(seconds: audioStart, preferredTimescale: 600),
                                end: CMTime(seconds: audioEnd, preferredTimescale: 600)),
                    of: audioTrack, at: audioAt)
                let parameters = audioParameters[index % 2]
                if head > 0 {
                    parameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                        timeRange: CMTimeRange(start: audioAt, duration: CMTime(seconds: head, preferredTimescale: 600)))
                } else {
                    parameters.setVolume(1, at: audioAt)
                }
                if tail > 0 {
                    let fadeAt = cursor + range.duration
                    parameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                        timeRange: CMTimeRange(start: fadeAt, duration: CMTime(seconds: tail, preferredTimescale: 600)))
                }
            }
            cursor = cursor + range.duration
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CompilationError.exportSetup
        }
        if !overlays.isEmpty {
            let transform = try await videoTrack.load(.preferredTransform)
            let natural = try await videoTrack.load(.naturalSize)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            let size = CGSize(width: abs(rect.width), height: abs(rect.height))
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = size
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
            let videoLayer = CALayer(); videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            for (time, caption) in overlays {
                let frame = try? generator.copyCGImage(at: CMTime(seconds: caption.sourceTime - 0.5, preferredTimescale: 600), actualTime: nil)
                let basketRight = frame.map { BasketSide.isRight($0) } ?? true
                let point = BasketSide.project(caption.location, right: basketRight)
                let label = CATextLayer()
                label.string = caption.text
                label.fontSize = max(24, size.height * 0.045)
                label.foregroundColor = NSColor.white.cgColor
                label.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
                label.alignmentMode = .center
                label.cornerRadius = 8
                label.contentsScale = 2
                let width = max(100, size.width * 0.12)
                let height = max(38, size.height * 0.07)
                label.frame = CGRect(x: min(max(point.x * size.width - width / 2, 0), size.width - width),
                                     y: min(max((1 - point.y) * size.height, 0), size.height - height),
                                     width: width, height: height)
                let start = max(0, time - 0.5), end = min(cursor.seconds, time + 1.5)
                let visibility = CAKeyframeAnimation(keyPath: "opacity")
                // A discrete step at each boundary keeps old captions hidden after their shot.
                let first = start / cursor.seconds
                let last = end / cursor.seconds
                if start == 0 {
                    visibility.values = [1, 0, 0]
                    visibility.keyTimes = [0, NSNumber(value: last), 1]
                } else {
                    visibility.values = [0, 1, 0, 0]
                    visibility.keyTimes = [0, NSNumber(value: first), NSNumber(value: last), 1]
                }
                visibility.calculationMode = .discrete
                visibility.beginTime = AVCoreAnimationBeginTimeAtZero
                visibility.duration = cursor.seconds
                visibility.isRemovedOnCompletion = false
                visibility.fillMode = .both
                label.opacity = 0
                label.add(visibility, forKey: "visibility")
                parent.addSublayer(label)
            }
            videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: videoLayer, in: parent)
            session.videoComposition = videoComposition
        }
        if !audioParameters.isEmpty { session.audioMix = mix }
        try await session.export(to: staged, as: .mp4)
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
        } else {
            try FileManager.default.moveItem(at: staged, to: destination)
        }
    }

    enum CompilationError: LocalizedError {
        case noVideo, noClips, trackSetup, exportSetup
        var errorDescription: String? {
            switch self {
            case .noVideo: "The selected file has no video track."
            case .noClips: "Include at least one clip before exporting."
            case .trackSetup: "Could not create the compilation tracks."
            case .exportSetup: "Could not create a video export session."
            }
        }
    }
}
