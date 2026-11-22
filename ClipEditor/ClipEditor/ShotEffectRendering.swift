import AVFoundation
import AppKit
import QuartzCore

enum ShotEffectRendering {
    static let duration = 1.2
    private static let fadeDuration = 0.2

    static func add(_ prepared: PreparedShotEffect, at time: Double, to parent: CALayer,
                    size: CGSize, timelineDuration: Double) {
        let effect = prepared.effect
        guard timelineDuration > 0,
              let shade = inverseMaskImage(effect) else { return }
        let dark = CALayer()
        dark.frame = CGRect(origin: .zero, size: size)
        dark.contents = shade
        dark.contentsGravity = .resize
        dark.opacity = 0
        let darkAnimation = CAKeyframeAnimation(keyPath: "opacity")
        let end = min(timelineDuration, time + duration)
        darkAnimation.values = [0, 0, 0.5, 0.5, 0, 0]
        darkAnimation.keyTimes = [0, NSNumber(value: time / timelineDuration),
                                  NSNumber(value: min(end, time + fadeDuration) / timelineDuration),
                                  NSNumber(value: end / timelineDuration),
                                  NSNumber(value: end / timelineDuration), 1]
        darkAnimation.beginTime = AVCoreAnimationBeginTimeAtZero
        darkAnimation.duration = timelineDuration
        darkAnimation.isRemovedOnCompletion = false
        darkAnimation.fillMode = .both
        dark.add(darkAnimation, forKey: "playerHighlight")
        parent.addSublayer(dark)

        let text = "\(effect.playerName)'s\n\(effect.shotDescription)\nat this area\n" +
            String(format: "%02d%% (%d/%d)", prepared.stats.percent,
                   prepared.stats.makes, prepared.stats.attempts)
        let font = NSFont.systemFont(ofSize: max(22, size.height * 0.037), weight: .bold)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let width = min(size.width * 0.42, max(240, size.width - 32))
        let textSize = (text as NSString).boundingRect(
            with: CGSize(width: width - 28, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes).size
        let height = min(size.height - 16, ceil(textSize.height) + 28)
        let image = textImage(text, size: CGSize(width: width - 28, height: height - 28), attributes: attributes)
        guard let image else { return }
        let scaleX = size.width / effect.frameSize.width
        let scaleY = size.height / effect.frameSize.height
        let box = effect.bounds
        let x = box.midX < effect.frameSize.width / 2
            ? box.maxX * scaleX + 16
            : box.minX * scaleX - width - 16
        let centerY = size.height - box.midY * scaleY
        let label = CALayer()
        label.frame = CGRect(x: min(max(8, x), size.width - width - 8),
                             y: min(max(8, centerY - height / 2), size.height - height - 8),
                             width: width, height: height)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.66).cgColor
        label.cornerRadius = 12
        label.opacity = 0
        let contents = CALayer()
        contents.frame = CGRect(x: 14, y: 14, width: width - 28, height: height - 28)
        contents.contents = image
        label.addSublayer(contents)
        let reveal = min(end, time + fadeDuration)
        let visibility = CAKeyframeAnimation(keyPath: "opacity")
        visibility.values = [0, 0, 1, 1, 0, 0]
        visibility.keyTimes = [0, NSNumber(value: reveal / timelineDuration),
                               NSNumber(value: min(end, reveal + 0.12) / timelineDuration),
                               NSNumber(value: end / timelineDuration),
                               NSNumber(value: end / timelineDuration), 1]
        visibility.beginTime = AVCoreAnimationBeginTimeAtZero
        visibility.duration = timelineDuration
        visibility.isRemovedOnCompletion = false
        visibility.fillMode = .both
        label.add(visibility, forKey: "effectTextVisibility")
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.8, 0.8, 1.08, 1, 1]
        pop.keyTimes = [0, NSNumber(value: reveal / timelineDuration),
                        NSNumber(value: min(end, reveal + 0.1) / timelineDuration),
                        NSNumber(value: min(end, reveal + 0.22) / timelineDuration), 1]
        pop.beginTime = AVCoreAnimationBeginTimeAtZero
        pop.duration = timelineDuration
        pop.isRemovedOnCompletion = false
        pop.fillMode = .both
        label.add(pop, forKey: "effectTextPop")
        parent.addSublayer(label)
    }

    private static func inverseMaskImage(_ effect: AppliedShotEffect) -> CGImage? {
        let width = Int(effect.frameSize.width)
        let height = Int(effect.frameSize.height)
        guard width > 0, height > 0, effect.maskPixels.count == width * height else { return nil }
        var pixels = Data(count: width * height * 4)
        effect.maskPixels.withUnsafeBytes { source in
            pixels.withUnsafeMutableBytes { destination in
                guard let mask = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let rgba = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for index in 0..<(width * height) {
                    rgba[index * 4 + 3] = 255 - mask[index]
                }
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8,
                       bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)
    }

    private static func textImage(_ text: String, size: CGSize,
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
        context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        (text as NSString).draw(with: CGRect(origin: .zero, size: size),
                                options: [.usesLineFragmentOrigin, .usesFontLeading],
                                attributes: attributes, context: nil)
        context.flushGraphics()
        return bitmap.cgImage
    }
}
