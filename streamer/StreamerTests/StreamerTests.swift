import AVFoundation
import Metal
import Testing
@testable import Streamer

private final class FixtureBundle {}

struct StreamerTests {
    @Test func frozenVideoReachesTwoSecondsDespiteAudio() async throws {
        let url = try #require(Bundle(for: FixtureBundle.self).url(
            forResource: "frozen-audible-small", withExtension: "mp4"
        ))
        let device = try #require(MTLCreateSystemDefaultDevice())
        let detector = try FrozenVideoDetector(device: device)
        let asset = AVURLAsset(url: url)
        let track = try #require(await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        #expect(reader.startReading())

        var firstFrozen: TimeInterval?
        var reachedTwoSeconds = false
        var frameCount = 0
        var sampledFrames = 0
        while let sample = output.copyNextSampleBuffer() {
            frameCount += 1
            let image = try #require(CMSampleBufferGetImageBuffer(sample))
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            var accepted = false
            let duration: TimeInterval? = await withCheckedContinuation { continuation in
                accepted = detector.inspect(image, at: time, completion: { continuation.resume(returning: $0) })
                if !accepted {
                    continuation.resume(returning: nil)
                }
            }
            if accepted { sampledFrames += 1 }
            if let duration {
                firstFrozen = firstFrozen ?? time
                if duration >= 2 { reachedTwoSeconds = true }
            }
        }
        #expect(reader.status == .completed)
        #expect(frameCount > 60)
        #expect(sampledFrames >= 5 && sampledFrames <= 7)
        #expect(firstFrozen != nil)
        #expect(reachedTwoSeconds)
    }
}
