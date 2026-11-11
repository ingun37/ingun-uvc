import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// First-pass intervals. These values can be filtered before a later merge/export step.
nonisolated enum VideoTimeMapper {
    enum Kind: Equatable, Sendable { case continuous, paused }

    struct Interval: Equatable, Sendable {
        let kind: Kind
        let period: String
        let videoStart: Double
        let videoEnd: Double
        let gameStart: Double
        let gameEnd: Double
    }

    typealias Recognizer = (CVPixelBuffer) throws -> GameTimeReader.Reading?

    static func map(videoURL: URL, format: GameTimeReader.ScoreboardFormat,
                    regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
                    margin: Double = 0.6,
                    recognize: Recognizer? = nil) async throws -> [Interval] {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MappingError.noVideo
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MappingError.invalidDuration }
        let frameRate = Double(try await track.load(.nominalFrameRate))
        let frameDuration = frameRate > 0 ? 1 / frameRate : 1 / 30
        let lastTime = max(0, duration - frameDuration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext()
        let read = recognize ?? { try GameTimeReader.read($0, format: format,
                                                        regionOfInterest: regionOfInterest) }
        var cache: [Double: GameTimeReader.Reading?] = [:]

        func reading(at time: Double) throws -> GameTimeReader.Reading? {
            if let cached = cache[time] { return cached }
            var actual = CMTime.zero
            let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 60000),
                                                  actualTime: &actual)
            var buffer: CVPixelBuffer?
            let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                kCVPixelFormatType_32BGRA, nil, &buffer)
            guard status == kCVReturnSuccess, let buffer else { throw MappingError.pixelBuffer }
            context.render(CIImage(cgImage: image), to: buffer)
            let result = try read(buffer)
            cache[time] = result
            return result
        }

        func divide(_ start: Double, _ end: Double) throws -> [Interval] {
            let first = try reading(at: start)
            let last = try reading(at: end)
            if let first, let last, first.period == last.period {
                if abs((first.gameSecond - last.gameSecond) - (end - start)) <= margin {
                    return [Interval(kind: .continuous, period: first.period,
                        videoStart: start, videoEnd: end,
                        gameStart: first.gameSecond, gameEnd: last.gameSecond)]
                }
                if first.gameSecond == last.gameSecond {
                    return [Interval(kind: .paused, period: first.period,
                        videoStart: start, videoEnd: end,
                        gameStart: first.gameSecond, gameEnd: last.gameSecond)]
                }
            }
            guard end - start >= 0.5 else { return [] }
            let middle = (start + end) / 2
            return try divide(start, middle) + divide(middle, end)
        }

        return merge(try divide(0, lastTime), margin: margin)
    }

    static func merge(_ intervals: [Interval], margin: Double = 0.6) -> [Interval] {
        var merged: [Interval] = []
        for interval in intervals {
            if let index = merged.indices.last {
                let previous = merged[index]
                let adjacent = abs(previous.videoEnd - interval.videoStart) < 0.000001
                let samePeriod = previous.period == interval.period
                let sameKind = previous.kind == interval.kind
                let sameClock = previous.kind == .paused && previous.gameEnd == interval.gameStart
                let continuousClock = previous.kind == .continuous &&
                    abs(previous.gameEnd - interval.gameStart) <= margin
                if adjacent && samePeriod && sameKind && (sameClock || continuousClock) {
                    merged[index] = Interval(kind: previous.kind, period: previous.period,
                        videoStart: previous.videoStart, videoEnd: interval.videoEnd,
                        gameStart: previous.gameStart, gameEnd: interval.gameEnd)
                    continue
                }
            }
            merged.append(interval)
        }
        return merged
    }

    private enum MappingError: Error { case noVideo, invalidDuration, pixelBuffer }
}
