import AVFoundation
import AppKit
import SwiftUI

enum BoxScoreVideo {
    static let duration = CMTime(seconds: 5, preferredTimescale: 600)

    @MainActor
    static func render<V: View>(_ view: V) throws -> CGImage {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.isOpaque = true
        guard let image = renderer.cgImage else { throw RenderError.image }
        return image
    }

    static func writeStill(_ image: CGImage, size: CGSize, to url: URL,
                           duration: Double = 5) async throws {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard width > 0, height > 0 else { throw RenderError.size }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw RenderError.writer }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? RenderError.writer }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int((duration * 30).rounded()) {
            while !input.isReadyForMoreMediaData { try Task.checkCancellation(); await Task.yield() }
            guard let pool = adaptor.pixelBufferPool else { throw RenderError.buffer }
            var maybeBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuffer) == kCVReturnSuccess,
                  let buffer = maybeBuffer else { throw RenderError.buffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            do {
                guard let address = CVPixelBufferGetBaseAddress(buffer),
                      let context = CGContext(data: address, width: width, height: height,
                          bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                          space: CGColorSpaceCreateDeviceRGB(),
                          bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                              CGImageAlphaInfo.premultipliedFirst.rawValue) else {
                    throw RenderError.buffer
                }
                context.setFillColor(NSColor.black.cgColor)
                context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
                let imageSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
                context.draw(image, in: CGRect(x: (CGFloat(width) - imageSize.width) / 2,
                                               y: (CGFloat(height) - imageSize.height) / 2,
                                               width: imageSize.width, height: imageSize.height))
            } catch {
                CVPixelBufferUnlockBaseAddress(buffer, [])
                throw error
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error ?? RenderError.writer
            }
        }
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? RenderError.writer }
    }

    enum RenderError: LocalizedError {
        case image, size, buffer, writer
        var errorDescription: String? {
            switch self {
            case .image: "Could not render the box score view."
            case .size: "The box score video size is invalid."
            case .buffer: "Could not create a box score video frame."
            case .writer: "Could not encode the box score video."
            }
        }
    }
}
