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
            guard let clockRange = text.range(of: #"(?<![\d:])(?:\d{1,2}:\d{2}(?:\.\d+)?|:\d{2}\.\d+)(?![\d.])"#,
                                              options: .regularExpression) else { continue }
            let parts = text[clockRange].split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let seconds = Double(parts[1]), seconds < 60 else { continue }
            let minutes = Int(parts[0]) ?? 0
            return Reading(period: period, gameSecond: Double(minutes * 60) + seconds)
        }
        return nil
    }

    static func add(_ reading: Reading, at start: Double, until end: Double,
                    discontinuous: Bool = false, to entries: inout [Entry]) {
        if !discontinuous, let last = entries.indices.last {
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

    typealias Recognizer = (CVPixelBuffer) throws -> [String]

    static func map(videoURL: URL, outputURL: URL, bottomDivisor: Int = 1,
                    recognize: Recognizer? = nil,
                    log: (String) -> Void = { _ in }) async throws -> [Entry] {
        guard bottomDivisor > 0 else { throw MappingError.invalidBottomDivisor }
        let recognizeFrame = recognize ?? { try visionTexts($0, bottomDivisor: bottomDivisor) }
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

        var entries: [Entry] = []
        let interval = 0.5
        var nextSample = 0.0
        var previousReading: Reading?
        var repeatedSince = 0.0
        var pending: (time: Double, buffer: CVPixelBuffer)?
        var inDuplicateRun = false
        var discontinuous = false
        func process(_ frame: (time: Double, buffer: CVPixelBuffer)) throws {
            let sampleTime = frame.time
            let buffer = frame.buffer
            let start = CFAbsoluteTimeGetCurrent()
            let texts = try recognizeFrame(buffer)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            let reading = parse(texts)
            log(String(format: "%.1fs → %@ | OCR %@ | %.1f ms", sampleTime,
                       reading.map { "\($0.period) game clock \($0.gameSecond)s" } ?? "no clock or period detected",
                       texts.description, elapsed))
            if let reading {
                if reading != previousReading { repeatedSince = sampleTime }
                if !discontinuous, sampleTime - repeatedSince >= 1.5,
                   let last = entries.indices.last,
                   entries[last].game_start_seconds != reading.gameSecond,
                   entries[last].video_start_seconds < repeatedSince {
                    entries[last].video_end_seconds = repeatedSince
                    entries[last].game_end_seconds = reading.gameSecond
                    entries.append(Entry(period: reading.period, game_start_seconds: reading.gameSecond,
                                         game_end_seconds: reading.gameSecond,
                                         video_start_seconds: repeatedSince,
                                         video_end_seconds: min(sampleTime + interval, duration)))
                } else {
                    add(reading, at: sampleTime, until: min(sampleTime + interval, duration),
                        discontinuous: discontinuous, to: &entries)
                }
                previousReading = reading
            } else {
                previousReading = nil
            }
            discontinuous = false
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
            let current = (time: nextSample, buffer: buffer)
            if let previous = pending {
                if identicalPixels(previous.buffer, current.buffer) {
                    if !inDuplicateRun, let reading = previousReading,
                       let last = entries.indices.last,
                       entries[last].period == reading.period,
                       entries[last].game_end_seconds == reading.gameSecond {
                        if entries[last].video_start_seconds >= repeatedSince {
                            entries.removeLast()
                        } else if entries[last].video_end_seconds > repeatedSince {
                            entries[last].video_end_seconds = repeatedSince
                        }
                    }
                    inDuplicateRun = true
                    discontinuous = true
                    previousReading = nil
                } else if inDuplicateRun {
                    inDuplicateRun = false
                    previousReading = nil
                } else {
                    try process(previous)
                }
            }
            pending = current
            nextSample += interval
        }
        if let pending, !inDuplicateRun {
            try process(pending)
        }
        guard reader.status == .completed else { throw reader.error ?? MappingError.readerFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(entries) + Data([0x0a])).write(to: outputURL, options: .atomic)
        return entries
    }

    private static func identicalPixels(_ lhs: CVPixelBuffer, _ rhs: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetWidth(lhs) == CVPixelBufferGetWidth(rhs),
              CVPixelBufferGetHeight(lhs) == CVPixelBufferGetHeight(rhs),
              CVPixelBufferGetPixelFormatType(lhs) == CVPixelBufferGetPixelFormatType(rhs),
              CVPixelBufferLockBaseAddress(lhs, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(lhs, .readOnly) }
        guard CVPixelBufferLockBaseAddress(rhs, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(rhs, .readOnly) }
        guard let left = CVPixelBufferGetBaseAddress(lhs),
              let right = CVPixelBufferGetBaseAddress(rhs) else { return false }
        let width = CVPixelBufferGetWidth(lhs) * 4
        let height = CVPixelBufferGetHeight(lhs)
        let leftStride = CVPixelBufferGetBytesPerRow(lhs)
        let rightStride = CVPixelBufferGetBytesPerRow(rhs)
        for row in 0..<height {
            if memcmp(left.advanced(by: row * leftStride),
                      right.advanced(by: row * rightStride), width) != 0 {
                return false
            }
        }
        return true
    }

    private static func visionTexts(_ buffer: CVPixelBuffer, bottomDivisor: Int) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 1 / CGFloat(bottomDivisor))
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }.map(\.string)
    }

    private enum MappingError: LocalizedError {
        case noVideo, invalidDuration, invalidBottomDivisor, readerSetup, readerFailed
        var errorDescription: String? {
            switch self {
            case .noVideo: "The file does not contain a video track."
            case .invalidDuration: "The video duration is invalid."
            case .invalidBottomDivisor: "The bottom divisor must be a positive integer."
            case .readerSetup: "Could not set up video decoding."
            case .readerFailed: "Video decoding failed."
            }
        }
    }
}
