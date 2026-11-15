import AVFoundation
import Metal
import Testing
@testable import GuraStreaming

struct GuraStreamingTests {
    @Test func frozenVideoTriggersTwoSecondTimeout() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "frozen-audible-small", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let track = try #require((try await asset.loadTracks(withMediaType: .video)).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let detector = try MetalFreezeDetector(renderer: MetalPreviewRenderer(device: device))
        let result = FreezeResult()
        detector.timeout = 2
        detector.onCountdown = { remaining in result.record(remaining) }
        detector.onTimeout = { result.timedOut() }
        detector.setActive(true)
        #expect(reader.startReading())
        while let sample = output.copyNextSampleBuffer() {
            if let frame = CMSampleBufferGetImageBuffer(sample) {
                detector.offer(frame, at: CMSampleBufferGetPresentationTimeStamp(sample))
                try await Task.sleep(for: .milliseconds(35))
            }
        }
        for _ in 0..<100 where !result.didTimeout {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(result.sawCountdown)
        #expect(result.didTimeout)
    }
}

private final class BundleMarker {}
private final class FreezeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var countdown = false
    private var timeout = false
    var sawCountdown: Bool { lock.lock(); defer { lock.unlock() }; return countdown }
    var didTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func record(_ remaining: Int?) { lock.lock(); if remaining != nil { countdown = true }; lock.unlock() }
    func timedOut() { lock.lock(); timeout = true; lock.unlock() }
}
