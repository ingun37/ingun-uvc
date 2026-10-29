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
        let game_second: Double
        var start_seconds: Double
        var end_seconds: Double
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
            guard let range = text.range(of: #"(?<!\d)(?:\d{1,2})?:\d{2}(?:\.\d+)?(?![\d.])"#, options: .regularExpression) else { continue }
            let parts = text[range].split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let seconds = Double(parts[1]), seconds < 60 else { continue }
            let minutes = Int(parts[0]) ?? 0
            return Reading(period: period, gameSecond: Double(minutes * 60) + seconds)
        }
        return nil
    }

    static func add(_ reading: Reading, at start: Double, until end: Double, to entries: inout [Entry]) {
        if let last = entries.indices.last,
           entries[last].period == reading.period,
           entries[last].game_second == reading.gameSecond,
           start <= entries[last].end_seconds + 0.000001 {
            entries[last].end_seconds = max(entries[last].end_seconds, end)
        } else {
            entries.append(Entry(period: reading.period, game_second: reading.gameSecond,
                                 start_seconds: start, end_seconds: end))
        }
    }

    typealias Recognizer = (CVPixelBuffer) throws -> [String]

    static func map(videoURL: URL, outputURL: URL, recognize: Recognizer = visionTexts) async throws -> [Entry] {
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
            if let reading = parse(try recognize(buffer)) {
                add(reading, at: nextSample, until: min(nextSample + interval, duration), to: &entries)
            }
            nextSample += interval
        }
        guard reader.status == .completed else { throw reader.error ?? MappingError.readerFailed }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(entries) + Data([0x0a])).write(to: outputURL, options: .atomic)
        return entries
    }

    private static func visionTexts(_ buffer: CVPixelBuffer) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first }
            .filter { $0.confidence >= 0.5 }.map(\.string)
    }

    private enum MappingError: LocalizedError {
        case noVideo, invalidDuration, readerSetup, readerFailed
        var errorDescription: String? {
            switch self {
            case .noVideo: "The file does not contain a video track."
            case .invalidDuration: "The video duration is invalid."
            case .readerSetup: "Could not set up video decoding."
            case .readerFailed: "Video decoding failed."
            }
        }
    }
}
