import AVFoundation
import Foundation
import AppKit
import QuartzCore

struct VideoCompilation {
    static func export(videoURL: URL, clips: [Clip], destination: URL,
                       title: String? = nil, subtitle: String? = nil,
                       player: String? = nil, square: Bool = false) async throws {
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
            overlays += clip.captions.filter {
                $0.sourceTime >= clip.start && $0.sourceTime < clip.end &&
                (player == nil || $0.player == player)
            }
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
        if !overlays.isEmpty || title != nil {
            let transform = try await videoTrack.load(.preferredTransform)
            let natural = try await videoTrack.load(.naturalSize)
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            let sourceSize = CGSize(width: abs(rect.width), height: abs(rect.height))
            let side = min(sourceSize.width, sourceSize.height)
            let size = square ? CGSize(width: side, height: side) : sourceSize
            let videoComposition = AVMutableVideoComposition()
            videoComposition.renderSize = size
            videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
            let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
            if square {
                outputVideo.preferredTransform = .identity
                let centered = transform.concatenating(CGAffineTransform(
                    translationX: -rect.minX + (side - sourceSize.width) / 2,
                    y: -rect.minY + (side - sourceSize.height) / 2
                ))
                layerInstruction.setTransform(centered, at: .zero)
            }
            instruction.layerInstructions = [layerInstruction]
            videoComposition.instructions = [instruction]
            let parent = CALayer(); parent.frame = CGRect(origin: .zero, size: size)
            let videoLayer = CALayer(); videoLayer.frame = parent.frame
            parent.addSublayer(videoLayer)
            if let title {
                // Adjust these two values to resize the per-player name and subtitle.
                let font = NSFont.systemFont(ofSize: max(26, size.height * 0.05), weight: .bold)
                let subtitleFont = NSFont.systemFont(ofSize: max(18, size.height * 0.028), weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
                let subtitleAttributes: [NSAttributedString.Key: Any] = [.font: subtitleFont, .foregroundColor: NSColor.white]
                let subtitleWidth = subtitle.map { ($0 as NSString).size(withAttributes: subtitleAttributes).width } ?? 0
                let width = min(size.width - 32, ceil(max((title as NSString).size(withAttributes: attributes).width,
                                                           subtitleWidth)) + 32)
                let titleHeight = ceil(font.ascender - font.descender + font.leading)
                let subtitleHeight = subtitle == nil ? 0 : ceil(subtitleFont.ascender - subtitleFont.descender + subtitleFont.leading)
                let height = titleHeight + subtitleHeight + (subtitle == nil ? 0 : 6) + 24
                let box = CALayer()
                box.frame = CGRect(x: (size.width - width) / 2, y: size.height - height - 16,
                                   width: width, height: height)
                box.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
                box.cornerRadius = 8
                if let image = captionImage(title, size: CGSize(width: width - 32, height: titleHeight), attributes: attributes) {
                    let label = CALayer()
                    label.frame = CGRect(x: 16, y: height - 12 - titleHeight, width: width - 32, height: titleHeight)
                    label.contents = image
                    box.addSublayer(label)
                }
                if let subtitle, let image = captionImage(subtitle,
                    size: CGSize(width: width - 32, height: subtitleHeight), attributes: subtitleAttributes) {
                    let label = CALayer()
                    label.frame = CGRect(x: 16, y: 12, width: width - 32, height: subtitleHeight)
                    label.contents = image
                    box.addSublayer(label)
                }
                parent.addSublayer(box)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let basketSide = try BasketSide()
            for (time, caption) in overlays {
                let point: CGPoint
                if player == nil {
                    let frame = try? generator.copyCGImage(at: CMTime(seconds: caption.sourceTime, preferredTimescale: 600), actualTime: nil)
                    let basketRight = try frame.map { try basketSide.isRight($0) } ?? true
                    point = BasketSide.project(caption.location, right: basketRight)
                } else {
                    point = CGPoint(x: 0.5, y: 0.9)
                }
                let captionText = player == nil ? caption.text : String(caption.text.split(separator: "\n").last ?? "")
                // Adjust these values to resize the per-player FGM/FGA caption.
                let playerCaptionFontSize = max(36, size.height * 0.065)
                let playerCaptionPadding: CGFloat = 24
                let font = NSFont.systemFont(
                    ofSize: player == nil ? max(24, size.height * 0.045) : playerCaptionFontSize,
                    weight: .semibold)
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = .center
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: font, .foregroundColor: player == nil ? NSColor.white : NSColor.black,
                    .paragraphStyle: paragraph
                ]
                let padding: CGFloat = player == nil ? 16 : playerCaptionPadding
                let naturalWidth = captionText.components(separatedBy: "\n")
                    .map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0
                let width = min(ceil(naturalWidth) + padding * 2, size.width - 16)
                let textBounds = (captionText as NSString).boundingRect(
                    with: CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
                let height = min(ceil(textBounds.height) + padding * 2, size.height - 16)
                let box = CALayer()
                box.backgroundColor = player == nil
                    ? NSColor.black.withAlphaComponent(0.75).cgColor : NSColor.white.cgColor
                box.cornerRadius = 8
                box.frame = CGRect(x: min(max(point.x * size.width - width / 2, 0), size.width - width),
                                   y: player == nil ? min(max((1 - point.y) * size.height, 0), size.height - height)
                                       : max(16, size.height * 0.1 - height / 2),
                                   width: width, height: height)
                let labelSize = CGSize(width: width - padding * 2, height: ceil(textBounds.height))
                guard let renderedText = captionImage(captionText, size: labelSize, attributes: attributes) else { continue }
                let label = CALayer()
                label.frame = CGRect(x: padding, y: (height - labelSize.height) / 2,
                                     width: labelSize.width, height: labelSize.height)
                label.contents = renderedText
                label.contentsScale = 2
                box.addSublayer(label)
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
                box.opacity = 0
                box.add(visibility, forKey: "visibility")
                parent.addSublayer(box)
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

    private static func captionImage(_ text: String, size: CGSize,
                                     attributes: [NSAttributedString.Key: Any]) -> CGImage? {
        let scale = 2
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)) * scale, pixelsHigh: Int(ceil(size.height)) * scale,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = previous }
        // Finish drawing before AVFoundation begins compositing the first caption frame.
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        (text as NSString).draw(with: CGRect(origin: .zero, size: size),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes, context: nil)
        context.flushGraphics()
        return bitmap.cgImage
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
