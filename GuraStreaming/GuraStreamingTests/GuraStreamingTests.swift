import AVFoundation
import Metal
import Testing
@testable import GuraStreaming

struct GuraStreamingTests {
    @Test func subregionMaskMatchesOnlyBottomLeft() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "subregion-binary-test", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let track = try #require((try await asset.loadTracks(withMediaType: .video)).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalPreviewRenderer(device: device)
        #expect(reader.startReading())
        let first = try #require(output.copyNextSampleBuffer())
        let firstFrame = try #require(CMSampleBufferGetImageBuffer(first))
        let third = 1.0 / 3.0
        let bottomLeft = CGRect(x: 0, y: 2 * third, width: third, height: third)
        let topRight = CGRect(x: 2 * third, y: 0, width: third, height: third)
        let mask = try #require(renderer.mask(from: firstFrame, region: bottomLeft))
        var counts = [0, 0, 0]
        var bottomLeftResults: [(time: Double, similar: Bool)] = []

        func check(_ sample: CMSampleBuffer) throws {
            let frame = try #require(CMSampleBufferGetImageBuffer(sample))
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let second = Int(time)
            guard (0..<3).contains(second) else { return }
            let leftResult: Bool? = renderer.isRegionSimilar(frame, to: mask, region: bottomLeft)
            let rightResult: Bool? = renderer.isRegionSimilar(frame, to: mask, region: topRight)
            let leftSimilar = try #require(leftResult)
            let rightSimilar = try #require(rightResult)
            if time < 0.9 || (time >= 1.1 && time < 1.9) || time >= 2.1 {
                #expect(leftSimilar == (second != 1), "Bottom-left result at \(time) seconds")
            }
            #expect(!rightSimilar, "Top-right result at \(time) seconds")
            bottomLeftResults.append((time, leftSimilar))
            counts[second] += 1
        }

        try check(first)
        while let sample = output.copyNextSampleBuffer() {
            try check(sample)
        }
        #expect(reader.status == .completed)
        #expect(counts.allSatisfy { $0 >= 20 }, "Expected frames in every second: \(counts)")
        let firstDifference = try #require(bottomLeftResults.first(where: { !$0.similar })?.time)
        let recovery = try #require(bottomLeftResults.first(where: { $0.time >= 1.9 && $0.similar })?.time)
        #expect((0.9...1.1).contains(firstDifference))
        #expect((1.9...2.1).contains(recovery))
    }

    @Test func maskMatchesFirstAndThirdSeconds() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "clip-binary-test-cropped", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        let track = try #require((try await asset.loadTracks(withMediaType: .video)).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let renderer = try MetalPreviewRenderer(device: device)
        #expect(reader.startReading())
        let first = try #require(output.copyNextSampleBuffer())
        let firstFrame = try #require(CMSampleBufferGetImageBuffer(first))
        let mask = try #require(renderer.wholeFrameMask(from: firstFrame))
        var counts = [0, 0, 0]
        var results: [(time: Double, similar: Bool)] = []

        func check(_ sample: CMSampleBuffer) throws {
            let frame = try #require(CMSampleBufferGetImageBuffer(sample))
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let second = Int(time)
            guard (0..<3).contains(second) else { return }
            let classification: Bool? = renderer.isWholeFrameSimilar(frame, to: mask)
            let similar = try #require(classification)
            if time < 0.9 || (time >= 1.1 && time < 1.9) || time >= 2.1 {
                #expect(similar == (second != 1), "Mask result at \(time) seconds")
            }
            results.append((time, similar))
            counts[second] += 1
        }

        try check(first)
        while let sample = output.copyNextSampleBuffer() {
            try check(sample)
        }
        #expect(reader.status == .completed)
        #expect(counts.allSatisfy { $0 >= 20 }, "Expected frames in every second: \(counts)")
        let firstDifference = try #require(results.first(where: { !$0.similar })?.time)
        let recovery = try #require(results.first(where: { $0.time >= 1.9 && $0.similar })?.time)
        #expect((0.9...1.1).contains(firstDifference))
        #expect((1.9...2.1).contains(recovery))
    }

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
