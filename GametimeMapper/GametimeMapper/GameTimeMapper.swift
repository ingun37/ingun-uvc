import AVFoundation
import Foundation
import Vision

nonisolated enum GameTimeMapper {
    struct Reading: Equatable, Sendable {
        let period: String
        let gameSecond: Double
    }

    struct Entry: Codable, Equatable, Sendable {
        let period: String
        let game_start_seconds: Double
        var game_end_seconds: Double
        var video_start_seconds: Double
        var video_end_seconds: Double
    }

    struct Sample: Sendable {
        let videoSecond: Double
        let reading: Reading?
        let logLine: String
    }

    struct RawReadings: Sendable {
        let samples: [Sample]
        let duration: Double
    }

    static func parse(_ texts: [String]) -> Reading? {
        let normalized = texts.map {
            $0.uppercased().replacingOccurrences(of: #"\s*([:.])\s*"#, with: "$1", options: .regularExpression)
        }
        let combined = texts.joined(separator: " ").uppercased()
            .replacingOccurrences(of: #"\s*([:.])\s*"#, with: "$1", options: .regularExpression)
        let candidates = normalized + [combined]
        guard let period = candidates.compactMap({ text -> String? in
            guard let range = text.range(of: #"(?<![A-Z0-9])(?:1ST|2ND|3RD|4TH|OT)(?![A-Z0-9])"#, options: .regularExpression) else { return nil }
            return String(text[range])
        }).first else { return nil }
        for text in candidates {
            guard let clockRange = text.range(of: #"(?<![\d:])(?:\d{1,2}:\d{2}(?:\.\d+)?|:?\d{1,2}\.\d+)(?![\d.])"#,
                                              options: .regularExpression) else { continue }
            let parts = text[clockRange].split(separator: ":", omittingEmptySubsequences: false)
            let secondsText = parts.count == 2 ? parts[1] : parts[0]
            guard let seconds = Double(secondsText), seconds < 60 else { continue }
            let minutes = parts.count == 2 ? (Int(parts[0]) ?? 0) : 0
            return Reading(period: period, gameSecond: Double(minutes * 60) + seconds)
        }
        return nil
    }

    static func add(_ reading: Reading, at start: Double, until end: Double,
                    to entries: inout [Entry]) {
        if let last = entries.indices.last {
            let entry = entries[last]
            let frozen = entry.game_start_seconds == entry.game_end_seconds &&
                entry.game_end_seconds == reading.gameSecond
            let gap = start - entry.video_end_seconds
            let expectedClock = frozen ? entry.game_end_seconds :
                entry.game_start_seconds - (start - entry.video_start_seconds)
            let tolerance = entry.game_start_seconds >= 60 && reading.gameSecond < 60 &&
                reading.gameSecond != reading.gameSecond.rounded() ? 1.0 : 0.51
            if entry.period == reading.period, gap >= -0.000001,
               (frozen || gap <= 1.000001),
               abs(expectedClock - reading.gameSecond) <= tolerance {
                entries[last].video_end_seconds = max(entries[last].video_end_seconds, end)
                entries[last].game_end_seconds = reading.gameSecond
                return
            }
        }
        entries.append(Entry(period: reading.period, game_start_seconds: reading.gameSecond,
                             game_end_seconds: reading.gameSecond,
                             video_start_seconds: start, video_end_seconds: end))
    }

    static func mergeContinuousIntervals(_ entries: [Entry]) -> [Entry] {
        var merged: [Entry] = []
        for entry in entries {
            if let last = merged.indices.last {
                let previous = merged[last]
                let videoGap = entry.video_start_seconds - previous.video_end_seconds
                let gameGap = previous.game_end_seconds - entry.game_start_seconds
                let previousPaused = previous.game_start_seconds == previous.game_end_seconds
                let entryPaused = entry.game_start_seconds == entry.game_end_seconds
                let continuous = !previousPaused && !entryPaused && gameGap >= 0 &&
                    abs(videoGap - gameGap) <= 1
                let samePausedTime = previousPaused && entryPaused &&
                    previous.game_end_seconds == entry.game_start_seconds
                if previous.period == entry.period, videoGap >= -0.000001,
                   (continuous || samePausedTime) {
                    merged[last].game_end_seconds = entry.game_end_seconds
                    merged[last].video_end_seconds = entry.video_end_seconds
                    continue
                }
            }
            merged.append(entry)
        }
        return merged
    }

    typealias Recognizer = (CVPixelBuffer) throws -> [String]

    static func map(videoURL: URL, outputURL: URL? = nil, bottomDivisor: Int = 1,
                    rightDivisor: Int = 1, leftDivisor: Int = 1, centerDivisor: Int = 1,
                    regionOfInterest: CGRect? = nil,
                    recognize: Recognizer? = nil,
                    log: (String) -> Void = { _ in },
                    onSample: (Sample) -> Void = { _ in }) async throws -> [Entry] {
        let raw = try await sample(videoURL: videoURL, bottomDivisor: bottomDivisor,
                                   rightDivisor: rightDivisor, leftDivisor: leftDivisor,
                                   centerDivisor: centerDivisor, regionOfInterest: regionOfInterest,
                                   recognize: recognize, log: log, onSample: onSample)
        let entries = merge(raw)
        if let outputURL { try save(entries, to: outputURL) }
        return entries
    }

    static func sample(videoURL: URL, bottomDivisor: Int = 1,
                       rightDivisor: Int = 1, leftDivisor: Int = 1, centerDivisor: Int = 1,
                       regionOfInterest: CGRect? = nil,
                       recognize: Recognizer? = nil,
                       log: (String) -> Void = { _ in },
                       onSample: (Sample) -> Void = { _ in }) async throws -> RawReadings {
        guard bottomDivisor > 0 else { throw MappingError.invalidBottomDivisor }
        guard rightDivisor > 0 else { throw MappingError.invalidRightDivisor }
        guard leftDivisor > 0 else { throw MappingError.invalidLeftDivisor }
        guard centerDivisor > 0 else { throw MappingError.invalidCenterDivisor }
        guard [rightDivisor, leftDivisor, centerDivisor].filter({ $0 > 1 }).count <= 1 else {
            throw MappingError.conflictingHorizontalDivisors
        }
        if let regionOfInterest {
            guard regionOfInterest.width > 0, regionOfInterest.height > 0,
                  CGRect(x: 0, y: 0, width: 1, height: 1).contains(regionOfInterest) else {
                throw MappingError.invalidRegion
            }
        }
        let recognizeFrame = recognize ?? { try visionTexts($0, bottomDivisor: bottomDivisor,
                                                            rightDivisor: rightDivisor,
                                                            leftDivisor: leftDivisor,
                                                            centerDivisor: centerDivisor,
                                                            selectedRegion: regionOfInterest) }
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MappingError.noVideo }
        let trackStart = try await track.load(.timeRange).start.seconds
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MappingError.invalidDuration }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MappingError.readerSetup }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MappingError.readerSetup }
        defer { reader.cancelReading() }

        var samples: [Sample] = []
        let interval = 0.5
        var nextSample = 0.0
        func process(_ frame: (time: Double, buffer: CVPixelBuffer)) throws {
            let sampleTime = frame.time
            let buffer = frame.buffer
            let start = CFAbsoluteTimeGetCurrent()
            let texts = try recognizeFrame(buffer)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let reading = parse(texts)
            let logLine = String(format: "%.1fs → %@ | OCR %@ | %.1f ms", sampleTime,
                       reading.map { "\($0.period) game clock \($0.gameSecond)s" } ?? "no clock or period detected",
                       texts.description, elapsed)
            log(logLine)
            let sample = Sample(videoSecond: sampleTime, reading: reading, logLine: logLine)
            samples.append(sample)
            onSample(sample)
        }
        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds - trackStart
            guard timestamp.isFinite, timestamp + 0.000001 >= nextSample,
                  nextSample < duration else { continue }
            if timestamp >= nextSample + interval {
                nextSample = floor(timestamp / interval) * interval
            }
            guard nextSample < duration,
                  let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
            try process((time: nextSample, buffer: buffer))
            nextSample += interval
        }
        guard reader.status == .completed else { throw reader.error ?? MappingError.readerFailed }
        return RawReadings(samples: samples, duration: duration)
    }

    static func merge(_ raw: RawReadings) -> [Entry] {
        var entries: [Entry] = []
        var previousReading: Reading?
        var repeatedSince = 0.0
        for sample in raw.samples {
                guard let reading = sample.reading else {
                    previousReading = nil
                    continue
                }
                let sampleTime = sample.videoSecond
                if reading != previousReading { repeatedSince = sampleTime }
                if sampleTime - repeatedSince >= 1.5,
                   let last = entries.indices.last,
                   entries[last].game_start_seconds != reading.gameSecond,
                   entries[last].video_start_seconds < repeatedSince {
                    entries[last].video_end_seconds = repeatedSince
                    entries[last].game_end_seconds = reading.gameSecond
                    entries.append(Entry(period: reading.period, game_start_seconds: reading.gameSecond,
                                         game_end_seconds: reading.gameSecond,
                                         video_start_seconds: repeatedSince,
                                         video_end_seconds: min(sampleTime + 0.5, raw.duration)))
                } else {
                    add(reading, at: sampleTime, until: min(sampleTime + 0.5, raw.duration),
                        to: &entries)
                }
                previousReading = reading
        }
        return mergeContinuousIntervals(entries)
    }

    static func save(_ entries: [Entry], to outputURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(entries) + Data([0x0a])).write(to: outputURL, options: .atomic)
    }

    static func regionOfInterest(bottomDivisor: Int, rightDivisor: Int,
                                 leftDivisor: Int = 1, centerDivisor: Int = 1) -> CGRect {
        let width = 1 / CGFloat(max(rightDivisor, leftDivisor, centerDivisor))
        let x = leftDivisor > 1 ? 0 : (centerDivisor > 1 ?
            CGFloat(centerDivisor - 1) / CGFloat(2 * centerDivisor) : 1 - width)
        return CGRect(x: x, y: 0,
                      width: width, height: 1 / CGFloat(bottomDivisor))
    }

    private static func visionTexts(_ buffer: CVPixelBuffer, bottomDivisor: Int,
                                    rightDivisor: Int, leftDivisor: Int,
                                    centerDivisor: Int, selectedRegion: CGRect?) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = selectedRegion ?? regionOfInterest(bottomDivisor: bottomDivisor,
                                                    rightDivisor: rightDivisor,
                                                    leftDivisor: leftDivisor,
                                                    centerDivisor: centerDivisor)
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }.map(\.string)
    }

    private enum MappingError: LocalizedError {
        case noVideo, invalidDuration, invalidRegion, invalidBottomDivisor, invalidRightDivisor, invalidLeftDivisor,
             invalidCenterDivisor,
             conflictingHorizontalDivisors, readerSetup, readerFailed
        var errorDescription: String? {
            switch self {
            case .noVideo: "The file does not contain a video track."
            case .invalidDuration: "The video duration is invalid."
            case .invalidRegion: "The selected scoreboard region is invalid."
            case .invalidBottomDivisor: "The bottom divisor must be a positive integer."
            case .invalidRightDivisor: "The right divisor must be a positive integer."
            case .invalidLeftDivisor: "The left divisor must be a positive integer."
            case .invalidCenterDivisor: "The center divisor must be a positive integer."
            case .conflictingHorizontalDivisors: "The left, center, and right divisors cannot be used together."
            case .readerSetup: "Could not set up video decoding."
            case .readerFailed: "Video decoding failed."
            }
        }
    }
}
