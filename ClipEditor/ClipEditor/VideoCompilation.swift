import AVFoundation
import Foundation
import AppKit
import QuartzCore

struct VideoCompilation {
    private static let boxScoreFadeSeconds = 0.45

    static func export(videoURL: URL, clips: [Clip], destination: URL,
                       title: String? = nil, subtitle: String? = nil,
                       player: String? = nil, square: Bool = false,
                       countEvents: [CountEvent] = [], endCard: CGImage? = nil) async throws {
        let staged = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: staged) }
        let stillURL = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-boxscore-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: stillURL) }
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
        let lastClipDuration = selected.last.map { max(0, $0.end - $0.start) } ?? 0
        let boxScoreFade = endCard == nil ? 0 : min(boxScoreFadeSeconds, lastClipDuration / 2)
        if boxScoreFade > 0, !audioParameters.isEmpty {
            let fadeTime = CMTime(seconds: boxScoreFade, preferredTimescale: 600)
            audioParameters[(selected.count - 1) % 2].setVolumeRamp(
                fromStartVolume: 1, toEndVolume: 0,
                timeRange: CMTimeRange(start: cursor - fadeTime, duration: fadeTime))
        }
        let transform = try await videoTrack.load(.preferredTransform)
        let natural = try await videoTrack.load(.naturalSize)
        let rect = CGRect(origin: .zero, size: natural).applying(transform)
        let sourceSize = CGSize(width: abs(rect.width), height: abs(rect.height))
        let side = min(sourceSize.width, sourceSize.height)
        let size = square ? CGSize(width: side, height: side) : sourceSize
        var cardTrack: AVMutableCompositionTrack?
        if let endCard {
            try await BoxScoreVideo.writeStill(endCard, size: size, to: stillURL)
            let stillAsset = AVURLAsset(url: stillURL)
            guard let source = try await stillAsset.loadTracks(withMediaType: .video).first,
                  let track = composition.addMutableTrack(withMediaType: .video,
                      preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw CompilationError.trackSetup
            }
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: BoxScoreVideo.duration),
                                      of: source, at: cursor)
            cardTrack = track
        }
        let totalDuration = cursor + (endCard == nil ? .zero : BoxScoreVideo.duration)
        let mix = AVMutableAudioMix()
        mix.inputParameters = audioParameters
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw CompilationError.exportSetup
        }
        if !overlays.isEmpty || title != nil || endCard != nil {
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
            if let cardTrack {
                let cardInstruction = AVMutableVideoCompositionInstruction()
                cardInstruction.timeRange = CMTimeRange(start: cursor, duration: BoxScoreVideo.duration)
                cardInstruction.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: cardTrack)]
                videoComposition.instructions = [instruction, cardInstruction]
            } else {
                videoComposition.instructions = [instruction]
            }
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
            if player != nil {
                addCountAnimation(to: parent, size: size, duration: cursor.seconds,
                                  clips: selected, player: player!, events: countEvents)
            }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let basketSide = try BasketSide()
            for (time, caption) in overlays {
                if player != nil { continue }
                let point: CGPoint
                if player == nil, let location = caption.location {
                    let frame = try? generator.copyCGImage(at: CMTime(seconds: caption.sourceTime, preferredTimescale: 600), actualTime: nil)
                    let basketRight = try frame.map { try basketSide.isRight($0) } ?? true
                    point = BasketSide.project(location, right: basketRight)
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
                                   y: player == nil && caption.location != nil
                                       ? min(max((1 - point.y) * size.height, 0), size.height - height)
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
            if let endCard {
                let card = CALayer()
                card.frame = parent.frame
                card.backgroundColor = NSColor.black.cgColor
                card.contents = endCard
                card.contentsGravity = .resizeAspect
                card.opacity = 0
                let visibility = CAKeyframeAnimation(keyPath: "opacity")
                if boxScoreFade > 0 {
                    visibility.values = [0, 0, 1, 1]
                    visibility.keyTimes = [0,
                        NSNumber(value: (cursor.seconds - boxScoreFade) / totalDuration.seconds),
                        NSNumber(value: cursor.seconds / totalDuration.seconds), 1]
                    visibility.calculationMode = .linear
                } else {
                    visibility.values = [0, 1, 1]
                    visibility.keyTimes = [0, NSNumber(value: cursor.seconds / totalDuration.seconds), 1]
                    visibility.calculationMode = .discrete
                }
                visibility.beginTime = AVCoreAnimationBeginTimeAtZero
                visibility.duration = totalDuration.seconds
                visibility.isRemovedOnCompletion = false
                visibility.fillMode = .both
                card.add(visibility, forKey: "boxScoreVisibility")
                parent.addSublayer(card)
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

    private static func addCountAnimation(to parent: CALayer, size: CGSize, duration: Double,
                                          clips: [Clip], player: String, events: [CountEvent]) {
        guard duration > 0 else { return }
        struct Change { let time: Double; let count: CountEvent? }
        var changes = [Change(time: 0, count: nil)]
        var shownAttempts = 0
        var cursor = 0.0
        for clip in clips {
            let shots = clip.captions.filter { $0.player == player &&
                $0.sourceTime >= clip.start && $0.sourceTime < clip.end
            }.sorted { $0.sourceTime < $1.sourceTime }
            for shot in shots {
                guard let countText = shot.text.components(separatedBy: "\n").last,
                      let attempts = Int(countText.split(separator: "/").last ?? ""),
                      attempts <= events.count else { continue }
                let gapEnd = max(shownAttempts, attempts - 1)
                if gapEnd > shownAttempts {
                    let available = min(0.85, max(0.1, shot.sourceTime - clip.start - 0.15))
                    for index in (shownAttempts + 1)...gapEnd {
                        let fraction = Double(index - shownAttempts) / Double(gapEnd - shownAttempts + 1)
                        changes.append(Change(time: cursor + available * fraction, count: events[index - 1]))
                    }
                }
                changes.append(Change(time: cursor + shot.sourceTime - clip.start, count: events[attempts - 1]))
                shownAttempts = attempts
            }
            cursor += clip.end - clip.start
        }
        changes.sort { $0.time < $1.time }
        let font = NSFont.systemFont(ofSize: max(36, size.height * 0.065), weight: .semibold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.black, .paragraphStyle: paragraph
        ]
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 12
        let centerY = max(56, size.height * 0.1)
        for (index, change) in changes.enumerated() {
            let count = change.count.map { "\($0.made)/\($0.attempted)" } ?? "0/0"
            let textSize = (count as NSString).size(withAttributes: attributes)
            let textWidth = ceil(textSize.width) + 4
            let textHeight = ceil(font.ascender - font.descender + font.leading) + 4
            let boxWidth = min(size.width - 16, textWidth + horizontalPadding * 2)
            let boxHeight = textHeight + verticalPadding * 2
            let frame = CGRect(x: (size.width - boxWidth) / 2,
                               y: max(16, centerY - boxHeight / 2),
                               width: boxWidth, height: boxHeight)
            let layer = CALayer()
            layer.frame = frame
            layer.backgroundColor = NSColor.white.cgColor
            layer.cornerRadius = 10
            layer.shadowColor = NSColor.black.cgColor
            layer.shadowOpacity = 0.94
            layer.shadowRadius = 24
            layer.shadowOffset = CGSize(width: 0, height: -3)
            layer.shadowPath = CGPath(roundedRect: layer.bounds, cornerWidth: 10,
                                      cornerHeight: 10, transform: nil)
            if let image = captionImage(count, size: CGSize(width: boxWidth - horizontalPadding * 2,
                                                            height: textHeight),
                                        attributes: attributes) {
                let label = CALayer()
                label.frame = CGRect(x: horizontalPadding, y: verticalPadding,
                                     width: boxWidth - horizontalPadding * 2, height: textHeight)
                label.contents = image
                label.contentsScale = 2
                layer.addSublayer(label)
            }
            let end = index + 1 < changes.count ? changes[index + 1].time : duration
            let visible = CAKeyframeAnimation(keyPath: "opacity")
            visible.values = change.time == 0 ? [1, 0, 0] : [0, 1, 0, 0]
            visible.keyTimes = change.time == 0
                ? [0, NSNumber(value: min(1, end / duration)), 1]
                : [0, NSNumber(value: min(1, change.time / duration)),
                   NSNumber(value: min(1, end / duration)), 1]
            visible.calculationMode = .discrete
            visible.beginTime = AVCoreAnimationBeginTimeAtZero
            visible.duration = duration
            visible.isRemovedOnCompletion = false
            visible.fillMode = .both
            layer.opacity = 0
            layer.add(visible, forKey: "visibility")
            if change.time > 0 && change.time < duration - 0.05 {
                let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                let span = min(0.42, duration - change.time)
                pop.values = [1, 1, 0.7, 1.17, 0.94, 1, 1]
                pop.keyTimes = [0, NSNumber(value: change.time / duration),
                                NSNumber(value: change.time / duration),
                                NSNumber(value: (change.time + span * 0.38) / duration),
                                NSNumber(value: (change.time + span * 0.7) / duration),
                                NSNumber(value: (change.time + span) / duration), 1]
                pop.beginTime = AVCoreAnimationBeginTimeAtZero
                pop.duration = duration
                pop.isRemovedOnCompletion = false
                pop.fillMode = .both
                layer.add(pop, forKey: "pop")
            }
            parent.addSublayer(layer)
            guard let event = change.count else { continue }
            let emoji = event.isMade ? "🏀 \(event.gameTime ?? "")" : "🧱"
            let desiredIconSize = size.height * 0.16
            let iconSize = min(110, max(64, desiredIconSize))
            let emojiFont = NSFont.systemFont(ofSize: iconSize * 0.78)
            let timeFont = NSFont.systemFont(ofSize: iconSize * 0.38, weight: .semibold)
            let iconAttributes: [NSAttributedString.Key: Any] = [.font: event.isMade ? timeFont : emojiFont]
            let iconWidth = event.isMade ? min(size.width - 16, ceil((emoji as NSString).size(withAttributes: iconAttributes).width) + 12) : iconSize
            guard let image = captionImage(emoji, size: CGSize(width: iconWidth, height: iconSize),
                                           attributes: iconAttributes) else { continue }
            let icon = CALayer()
            icon.contents = image
            // +10 is heuristic adjustment to align center
            icon.frame = CGRect(x: frame.midX - iconWidth / 2 + 10, y: frame.maxY + 6,
                                width: iconWidth, height: iconSize)
            icon.opacity = 0
            guard change.time < duration - 0.05 else { continue }
            let span = min(0.7, duration - change.time)
            let bounce = CAKeyframeAnimation(keyPath: "position.y")
            let y = icon.position.y
            bounce.values = [y + 90, y + 90, y - 24, y + 12, y, y]
            bounce.keyTimes = [0, NSNumber(value: change.time / duration),
                               NSNumber(value: (change.time + span * 0.35) / duration),
                               NSNumber(value: (change.time + span * 0.57) / duration),
                               NSNumber(value: (change.time + span * 0.8) / duration), 1]
            bounce.beginTime = AVCoreAnimationBeginTimeAtZero
            bounce.duration = duration
            bounce.isRemovedOnCompletion = false
            bounce.fillMode = .both
            icon.add(bounce, forKey: "bounce")
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0, 1, 1, 0, 0]
            fade.keyTimes = [0, NSNumber(value: change.time / duration),
                             NSNumber(value: (change.time + span * 0.12) / duration),
                             NSNumber(value: (change.time + span * 0.72) / duration),
                             NSNumber(value: (change.time + span) / duration), 1]
            fade.beginTime = AVCoreAnimationBeginTimeAtZero
            fade.duration = duration
            fade.isRemovedOnCompletion = false
            fade.fillMode = .both
            icon.add(fade, forKey: "fade")
            parent.addSublayer(icon)
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
