import AVFoundation
import Observation
import SwiftUI

/// A selection in the displayed video's pixel coordinate system (top-left origin).
struct VideoRegion {
    var rect: CGRect

    var isValid: Bool { rect.width > 0 && rect.height > 0 }
    var aspectRatio: CGFloat { rect.height > 0 ? rect.width / rect.height : 0 }
}

@MainActor
@Observable
final class VideoSession {
    let player = AVPlayer()
    var url: URL?
    var videoSize = CGSize.zero
    var duration: Double = 0
    var currentTime: Double = 0
    var isPlaying = false
    var isLoading = false
    var errorMessage: String?
    var region: VideoRegion?
    private var sourceSize = CGSize.zero
    private var displayBounds = CGRect.zero
    private var videoTransform = CGAffineTransform.identity
    private var scopedURL: URL?

    func open(_ url: URL) async -> Bool {
        close()
        isLoading = true
        defer { isLoading = false }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw VideoError.noVideo
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform)
            let seconds = try await asset.load(.duration).seconds
            guard bounds.width != 0, bounds.height != 0, seconds.isFinite, seconds > 0,
                  try await asset.load(.isPlayable) else { throw VideoError.unplayable }
            videoSize = CGSize(width: abs(bounds.width), height: abs(bounds.height))
            sourceSize = size
            displayBounds = bounds
            videoTransform = transform
            duration = seconds
            self.url = url
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            return true
        } catch {
            close()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func refreshPlayback() {
        if let error = player.currentItem?.error { errorMessage = error.localizedDescription }
        let seconds = player.currentTime().seconds
        if seconds.isFinite { currentTime = min(max(seconds, 0), duration) }
        isPlaying = player.rate != 0
    }

    func togglePlayback() {
        if player.rate != 0 {
            pause()
        } else {
            if currentTime >= duration { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to seconds: Double) {
        currentTime = min(max(seconds, 0), duration)
        player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func decoderRegion() -> (x: Int, y: Int, width: Int, height: Int)? {
        guard let region, region.isValid else { return nil }
        let displayRect = region.rect.offsetBy(dx: displayBounds.minX, dy: displayBounds.minY)
        let sourceRect = displayRect.applying(videoTransform.inverted()).standardized
            .intersection(CGRect(origin: .zero, size: sourceSize))
        guard !sourceRect.isNull else { return nil }
        let x = max(0, Int(floor(sourceRect.minX)))
        let y = max(0, Int(floor(sourceRect.minY)))
        let right = min(Int(sourceSize.width), Int(ceil(sourceRect.maxX)))
        let bottom = min(Int(sourceSize.height), Int(ceil(sourceRect.maxY)))
        guard right > x, bottom > y else { return nil }
        return (x, y, right - x, bottom - y)
    }

    func close() {
        pause()
        player.replaceCurrentItem(with: nil)
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        url = nil
        region = nil
        duration = 0
        currentTime = 0
        videoSize = .zero
        sourceSize = .zero
        displayBounds = .zero
        videoTransform = .identity
    }

    private enum VideoError: LocalizedError {
        case noVideo, unplayable
        var errorDescription: String? {
            switch self {
            case .noVideo: "The selected file does not contain a video track."
            case .unplayable: "This video cannot be played. Choose another video file."
            }
        }
    }
}
