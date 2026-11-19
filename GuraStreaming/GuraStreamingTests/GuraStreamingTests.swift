import AVFoundation
import Metal
import Testing
@testable import GuraStreaming

struct GuraStreamingTests {
    @Test func thumbnailLogIsWrittenWhenRecordingEnds() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let detector = ThumbnailCandidateDetector()
        detector.start(for: root.appendingPathComponent("sample.mov"))
        let result = await withCheckedContinuation { continuation in
            detector.finish { continuation.resume(returning: $0) }
        }
        let csv = try result.get()
        #expect(csv.path == root.appendingPathComponent("sample-thumbnail-candidates/log.csv").path)
        #expect(try String(contentsOf: csv, encoding: .utf8)
                == "video_timestamp,image_path,positive_score,positive_prompt,negative_score,negative_prompt,score_margin,top_1,top_2,top_3,top_4,top_5,bottom_1,bottom_2,bottom_3,bottom_4,bottom_5\n")
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

    @Test func videoWithoutAudioTriggersTwoSecondSilenceTimeout() async throws {
        let url = try #require(Bundle(for: BundleMarker.self).url(forResource: "no_audio", withExtension: "mp4"))
        let asset = AVURLAsset(url: url)
        #expect(try await asset.loadTracks(withMediaType: .audio).isEmpty)
        let track = try #require((try await asset.loadTracks(withMediaType: .video)).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)

        let detector = AudioSilenceDetector()
        let result = SilenceResult()
        detector.start(timeout: 2, onCountdown: { result.record($0) }) { result.timedOut() }
        defer { detector.stop() }
        #expect(reader.startReading())
        let started = ProcessInfo.processInfo.systemUptime
        var firstTimestamp: Double?
        var lastTimestamp = 0.0
        while let sample = output.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if firstTimestamp == nil { firstTimestamp = timestamp }
            lastTimestamp = timestamp
            let videoElapsed = timestamp - firstTimestamp!
            let wallElapsed = ProcessInfo.processInfo.systemUptime - started
            let delay = max(0, videoElapsed - wallElapsed)
            if delay > 0 { try await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
        }
        #expect(lastTimestamp - (firstTimestamp ?? 0) >= 2.9)
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

private final class SilenceResult: @unchecked Sendable {
    private let lock = NSLock()
    private var countdown = false
    private var timeout = false
    var sawCountdown: Bool { lock.lock(); defer { lock.unlock() }; return countdown }
    var didTimeout: Bool { lock.lock(); defer { lock.unlock() }; return timeout }
    func record(_ remaining: Int?) { lock.lock(); if remaining != nil { countdown = true }; lock.unlock() }
    func timedOut() { lock.lock(); timeout = true; lock.unlock() }
}
