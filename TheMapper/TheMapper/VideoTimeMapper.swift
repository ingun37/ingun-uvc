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
                    recognize: Recognizer? = nil,
                    log: (String) -> Void = { _ in }) async throws -> [Interval] {
        let started = CFAbsoluteTimeGetCurrent()
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
            let result: GameTimeReader.Reading?
            let texts: [String]?
            if let recognize {
                result = try recognize(buffer)
                texts = nil
            } else {
                let observation = try GameTimeReader.readWithTexts(buffer, format: format,
                    regionOfInterest: regionOfInterest)
                result = observation.reading
                texts = observation.texts
            }
            cache[time] = result
            let clock = result.map { "\($0.period) \($0.gameSecond)s" } ?? "no clock detected"
            let ocr = texts.map { " | OCR \($0)" } ?? ""
            if texts?.isEmpty != true {
                log(String(format: "%.2fs → %@%@", time, clock, ocr))
            }
            return result
        }

        func divide(_ start: Double, _ end: Double) throws -> [Interval] {
            let first = try reading(at: start)
            let last = try reading(at: end)
            if let first, let last, first.period == last.period {
                if first.gameSecond == last.gameSecond {
                    return [Interval(kind: .paused, period: first.period,
                        videoStart: start, videoEnd: end,
                        gameStart: first.gameSecond, gameEnd: last.gameSecond)]
                }
                if abs((first.gameSecond - last.gameSecond) - (end - start)) <= margin {
                    return [Interval(kind: .continuous, period: first.period,
                        videoStart: start, videoEnd: end,
                        gameStart: first.gameSecond, gameEnd: last.gameSecond)]
                }
            }
            guard end - start >= 0.5 else { return [] }
            let middle = (start + end) / 2
            return try divide(start, middle) + divide(middle, end)
        }

        let found = try divide(0, lastTime)
        let intervals = merge(found, margin: margin)
        let continuous = found.filter { $0.kind == .continuous }
            .reduce(0.0) { $0 + $1.videoEnd - $1.videoStart }
        let paused = found.filter { $0.kind == .paused }
            .reduce(0.0) { $0 + $1.videoEnd - $1.videoStart }
        log(String(format: "Finished: %.2f s elapsed | %d intervals | continuous %.2f s, paused %.2f s, covered %.2f / %.2f s | %d OCR frames (%.0f at 0.5 s sampling)",
                   CFAbsoluteTimeGetCurrent() - started, intervals.count,
                   continuous, paused, continuous + paused, duration,
                   cache.count, ceil(duration / 0.5)))
        return intervals
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
                if samePeriod && sameKind && (sameClock || (adjacent && continuousClock)) {
                    merged[index] = Interval(kind: previous.kind, period: previous.period,
                        videoStart: previous.videoStart, videoEnd: interval.videoEnd,
                        gameStart: previous.gameStart, gameEnd: interval.gameEnd)
                    continue
                }
            }
            merged.append(interval)
        }
        var bridged: [Interval] = []
        var index = 0
        while index < merged.count {
            if index + 2 < merged.count {
                let first = merged[index]
                let middle = merged[index + 1]
                let last = merged[index + 2]
                let shortPause = middle.videoEnd - middle.videoStart < 0.5
                let clockMatchesVideo = abs((first.gameEnd - last.gameStart) -
                    (last.videoStart - first.videoEnd)) <= margin
                let fullRangeMatches = abs((first.gameStart - last.gameEnd) -
                    (last.videoEnd - first.videoStart)) <= margin
                if first.kind == .continuous, middle.kind == .paused,
                   last.kind == .continuous, shortPause,
                   first.period == middle.period, middle.period == last.period,
                   abs(first.videoEnd - middle.videoStart) < 0.000001,
                   middle.videoEnd <= last.videoStart,
                   first.gameEnd == middle.gameStart,
                   middle.gameEnd >= last.gameStart,
                   clockMatchesVideo, fullRangeMatches {
                    bridged.append(Interval(kind: .continuous, period: first.period,
                        videoStart: first.videoStart, videoEnd: last.videoEnd,
                        gameStart: first.gameStart, gameEnd: last.gameEnd))
                    index += 3
                    continue
                }
            }
            bridged.append(merged[index])
            index += 1
        }
        return bridged
    }

    private enum MappingError: Error { case noVideo, invalidDuration, pixelBuffer }
}
