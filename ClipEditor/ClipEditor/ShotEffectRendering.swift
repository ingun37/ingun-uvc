import AVFoundation
import AppKit
import QuartzCore

enum ShotEffectRendering {
    private static let fadeDuration = 0.2

    static func add(_ prepared: PreparedShotEffect, at time: Double, to parent: CALayer,
                    size: CGSize, timelineDuration: Double, settings: ShotEffectSettings,
                    crop: CGRect? = nil) {
        let effect = prepared.effect
        let frameCrop = crop ?? CGRect(origin: .zero, size: effect.frameSize)
        guard timelineDuration > 0,
              frameCrop.width > 0, frameCrop.height > 0,
              let shade = inverseMaskImage(effect, settings: settings)?.cropping(to: frameCrop) else { return }
        let dark = CALayer()
        dark.frame = CGRect(origin: .zero, size: size)
        dark.contents = shade
        dark.contentsGravity = .resize
        dark.opacity = 0
        let darkAnimation = CAKeyframeAnimation(keyPath: "opacity")
        let end = min(timelineDuration, time + settings.duration)
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

        let area = ShotEffectArea.ellipse(atBottomOf: effect.bounds, in: effect.frameSize,
                                            settings: settings)
        let scaleX = size.width / frameCrop.width
        let scaleY = size.height / frameCrop.height
        let areaRect = CGRect(x: (area.minX - frameCrop.minX) * scaleX,
                              y: size.height - (area.maxY - frameCrop.minY) * scaleY,
                              width: area.width * scaleX,
                              height: area.height * scaleY)
        let areaLayer = CAShapeLayer()
        areaLayer.frame = CGRect(origin: .zero, size: size)
        areaLayer.path = CGPath(ellipseIn: areaRect, transform: nil)
        areaLayer.fillColor = ColorTheme.fontColor2NS.withAlphaComponent(0.2).cgColor
        areaLayer.strokeColor = ColorTheme.fontColor2NS.cgColor
        areaLayer.lineWidth = max(2, size.height * 0.003)
        areaLayer.opacity = 0
        let areaVisibility = CAKeyframeAnimation(keyPath: "opacity")
        areaVisibility.values = [0, 0, 1, 1, 0, 0]
        areaVisibility.keyTimes = [0, NSNumber(value: time / timelineDuration),
                                   NSNumber(value: min(end, time + fadeDuration) / timelineDuration),
                                   NSNumber(value: end / timelineDuration),
                                   NSNumber(value: end / timelineDuration), 1]
        areaVisibility.beginTime = AVCoreAnimationBeginTimeAtZero
        areaVisibility.duration = timelineDuration
        areaVisibility.isRemovedOnCompletion = false
        areaVisibility.fillMode = .both
        areaLayer.add(areaVisibility, forKey: "areaVisibility")
        parent.addSublayer(areaLayer)

        let font = NSFont.systemFont(ofSize: max(22, size.height * 0.037), weight: .bold)
        let caption = caption(for: prepared, font: font)
        let text = caption.string
        let attributes = caption.attributes(at: 0, effectiveRange: nil)
        let padding: CGFloat = 14
        let lineWidth = text.components(separatedBy: "\n")
            .map { ($0 as NSString).size(withAttributes: attributes).width }
            .max() ?? 0
        let maximumWidth = min(size.width - 16, max(240, size.width * 0.42))
        let width = min(maximumWidth, ceil(lineWidth) + padding * 2)
        let textSize = caption.boundingRect(
            with: CGSize(width: width - padding * 2, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        let height = min(size.height - 16, ceil(textSize.height) + padding * 2)
        let image = textImage(caption, size: CGSize(width: width - padding * 2,
                                                    height: height - padding * 2))
        guard let image else { return }
        let box = effect.bounds
        let x = box.midX < frameCrop.midX
            ? (box.maxX - frameCrop.minX) * scaleX + 16
            : (box.minX - frameCrop.minX) * scaleX - width - 16
        let centerY = size.height - (box.midY - frameCrop.minY) * scaleY
        let label = CALayer()
        label.frame = CGRect(x: min(max(8, x), size.width - width - 8),
                             y: min(max(8, centerY - height / 2), size.height - height - 8),
                             width: width, height: height)
        label.backgroundColor = NSColor.black.withAlphaComponent(0.66).cgColor
        label.cornerRadius = 12
        label.opacity = 0
        let contents = CALayer()
        contents.frame = CGRect(x: padding, y: padding,
                                width: width - padding * 2, height: height - padding * 2)
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

    static func caption(for prepared: PreparedShotEffect, font: NSFont) -> NSAttributedString {
        let effect = prepared.effect
        let percentage = String(format: "%02d%%", prepared.stats.percent)
        let text = "\(effect.playerName)'s\nrecent\n\(effect.shotDescription)\nat the\n\(prepared.spotLabel)\n" +
            "\(percentage) (\(prepared.stats.makes)/\(prepared.stats.attempts))"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: ColorTheme.fontColor1NS,
            .paragraphStyle: paragraph
        ]
        let caption = NSMutableAttributedString(string: text, attributes: attributes)
        caption.addAttribute(.foregroundColor, value: ColorTheme.fontColor2NS,
                             range: (text as NSString).range(of: prepared.spotLabel, options: .backwards))
        caption.addAttribute(.foregroundColor, value: ColorTheme.shotPercentageColor(prepared.stats.percent),
                             range: (text as NSString).range(of: percentage, options: .backwards))
        return caption
    }

    private static func inverseMaskImage(_ effect: AppliedShotEffect,
                                         settings: ShotEffectSettings) -> CGImage? {
        let width = Int(effect.frameSize.width)
        let height = Int(effect.frameSize.height)
        guard width > 0, height > 0, effect.maskPixels.count == width * height else { return nil }
        let area = ShotEffectArea.ellipse(atBottomOf: effect.bounds, in: effect.frameSize,
                                            settings: settings)
        let radiusX = max(area.width / 2, 1)
        let radiusY = max(area.height / 2, 1)
        var pixels = Data(count: width * height * 4)
        effect.maskPixels.withUnsafeBytes { source in
            pixels.withUnsafeMutableBytes { destination in
                guard let mask = source.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let rgba = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for y in 0..<height {
                    let normalizedY = (CGFloat(y) + 0.5 - area.midY) / radiusY
                    for x in 0..<width {
                        let index = y * width + x
                        let normalizedX = (CGFloat(x) + 0.5 - area.midX) / radiusX
                        let insideArea = normalizedX * normalizedX + normalizedY * normalizedY <= 1
                        rgba[index * 4 + 3] = insideArea ? 0 : 255 - mask[index]
                    }
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

    private static func textImage(_ text: NSAttributedString, size: CGSize) -> CGImage? {
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
        text.draw(with: CGRect(origin: .zero, size: size),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        context.flushGraphics()
        return bitmap.cgImage
    }
}
