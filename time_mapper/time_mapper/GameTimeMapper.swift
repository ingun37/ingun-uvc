import AVFoundation
import Foundation
import Vision

nonisolated enum GameTimeMapper {
    struct Region: Sendable {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    struct Entry: Codable, Equatable, Sendable {
        let game_second: Int
        var start_seconds: Double
        var end_seconds: Double
    }

    static func parseClock(_ texts: [String]) -> Int? {
        for text in texts + [texts.joined(separator: " ")] {
            let normalized = text.replacingOccurrences(of: #"\s*([:.])\s*"#, with: "$1", options: .regularExpression)
            let pattern = #"(?<!\d)(?:(\d{1,2}):(\d{2})|:(\d{2})\.(\d))(?!\d)"#
            guard let match = normalized.range(of: pattern, options: .regularExpression) else { continue }
            let clock = String(normalized[match])
            let parts = clock.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            let minutes = Int(parts[0]) ?? 0
            let secondsText = parts[1].split(separator: ".")[0]
            guard let seconds = Int(secondsText), seconds < 60 else { continue }
            return minutes * 60 + seconds
        }
        return nil
    }

    static func add(_ second: Int, at start: Double, until end: Double, to entries: inout [Entry]) {
        if let last = entries.indices.last,
           entries[last].game_second == second,
           start <= entries[last].end_seconds + 0.000001 {
            entries[last].end_seconds = max(entries[last].end_seconds, end)
        } else {
            entries.append(Entry(game_second: second, start_seconds: start, end_seconds: end))
        }
    }

    static func map(videoURL: URL, outputURL: URL, region: Region,
                    log: @Sendable (String) -> Void) async throws {
        let asset = AVURLAsset(url: videoURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MappingError.noVideo
        }
        let size = try await track.load(.naturalSize)
        let trackStart = try await track.load(.timeRange).start.seconds
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0,
              region.x >= 0, region.y >= 0, region.width > 0, region.height > 0,
              region.x + region.width <= Int(size.width),
              region.y + region.height <= Int(size.height) else {
            throw MappingError.invalidRegion
        }
        log("Opening video: \(videoURL.lastPathComponent)")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MappingError.readerSetup }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MappingError.readerSetup }
        defer { reader.cancelReading() }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        // Vision's region is bottom-left based; the selection is top-left based.
        request.regionOfInterest = CGRect(
            x: Double(region.x) / size.width,
            y: 1 - Double(region.y + region.height) / size.height,
            width: Double(region.width) / size.width,
            height: Double(region.height) / size.height
        )
        let handler = VNSequenceRequestHandler()
        var entries: [Entry] = []
        var nextSample = 0.0
        let interval = 0.5
        log("Video ready: \(Int(size.width)) × \(Int(size.height)); sampling every 0.5 seconds")

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
            let start = CFAbsoluteTimeGetCurrent()
            try handler.perform([request], on: buffer)
            let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first }
                .filter { $0.confidence >= 0.5 }.map(\.string)
            let second = parseClock(texts)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
            log(String(format: "%.1fs → %@ | OCR %@ | %.1f ms", nextSample,
                       second.map { "game clock \($0)s" } ?? "no clock detected",
                       texts.description, elapsed))
            if let second {
                add(second, at: nextSample, until: min(nextSample + interval, duration), to: &entries)
            }
            nextSample += interval
        }
        guard reader.status == .completed else { throw reader.error ?? MappingError.readerFailed }
        log("Writing \(entries.count) mapping ranges")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries) + Data([0x0a])
        try data.write(to: outputURL, options: .withoutOverwriting)
        log("Mapping saved: \(outputURL.lastPathComponent)")
    }

    private enum MappingError: LocalizedError {
        case noVideo, invalidRegion, readerSetup, readerFailed
        var errorDescription: String? {
            switch self {
            case .noVideo: "The selected file does not contain a video track."
            case .invalidRegion: "The selected region lies outside the video frame."
            case .readerSetup: "Could not set up video decoding."
            case .readerFailed: "Video decoding failed."
            }
        }
    }
}
