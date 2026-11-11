import AVFoundation
import Foundation
import Vision

nonisolated enum GameTimeMapper {
    enum Period: String, CaseIterable, Identifiable, Sendable {
        case first = "First Quarter", second = "Second Quarter"
        case third = "Third Quarter", fourth = "Fourth Quarter"
        case firstOvertime = "First Overtime", secondOvertime = "Second Overtime"
        case thirdOvertime = "Third Overtime"

        var id: String { rawValue }
        var shortLabel: String {
            switch self {
            case .first: "1ST"
            case .second: "2ND"
            case .third: "3RD"
            case .fourth: "4TH"
            case .firstOvertime, .secondOvertime, .thirdOvertime: "OT"
            }
        }
        var longLabel: String {
            switch self {
            case .first: "FIRST QUARTER"
            case .second: "SECOND QUARTER"
            case .third: "THIRD QUARTER"
            case .fourth: "FOURTH QUARTER"
            case .firstOvertime, .secondOvertime, .thirdOvertime: "OVERTIME"
            }
        }
    }

    enum PeriodStyle: String, CaseIterable, Sendable { case short, long }
    enum UnderMinuteStyle: String, CaseIterable, Sendable { case colon, natural, doubleDigit }

    struct ScoreboardFormat: Equatable, Sendable {
        var periodStyles: [Period: PeriodStyle]
        var underMinuteStyle: UnderMinuteStyle

        init(periodStyle: PeriodStyle, underMinuteStyle: UnderMinuteStyle) {
            self.periodStyles = Dictionary(uniqueKeysWithValues: Period.allCases.map { ($0, periodStyle) })
            self.underMinuteStyle = underMinuteStyle
        }

        enum Preset: String, CaseIterable, Identifiable {
            case a = "Preset A — Short Period, Digital Time"
            case b = "Preset B — Long Period, Natural Time"
            case c = "Preset C — Short Period, Natural Time"
            var id: String { rawValue }
            var format: ScoreboardFormat {
                switch self {
                case .a: ScoreboardFormat(periodStyle: .short, underMinuteStyle: .colon)
                case .b: ScoreboardFormat(periodStyle: .long, underMinuteStyle: .natural)
                case .c: ScoreboardFormat(periodStyle: .short, underMinuteStyle: .natural)
                }
            }
        }

        var preset: Preset? { Preset.allCases.first { $0.format == self } }
    }

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
        let id: Int
        let videoSecond: Double
        let reading: Reading?
        let ocrTexts: [String]
        let logLine: String
    }

    struct RawReadings: Sendable {
        let samples: [Sample]
        let duration: Double

        func removingSample(id: Int) -> RawReadings {
            RawReadings(samples: samples.filter { $0.id != id }, duration: duration)
        }
    }

    static func parse(_ texts: [String], format: ScoreboardFormat? = nil) -> Reading? {
        func normalizedClockText(_ text: String) -> String {
            text.uppercased()
                .replacingOccurrences(of: #"(?<![\d.])(\d{1,2})\s*:\s*(?=\d)"#,
                                      with: "$1:", options: .regularExpression)
                .replacingOccurrences(of: #":\s+(?=\d)"#, with: ":", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=\d)\s*\.\s*(?=\d)"#, with: ".", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=:[0-5])Б(?![\p{L}0-9])"#,
                                      with: "6", options: .regularExpression)
        }
        let normalized = texts.map(normalizedClockText)
        let combined = normalizedClockText(texts.joined(separator: " "))
        let candidates = normalized + [combined]
        var labels: [(label: String, canonical: String)] = format.map { selection in
            Period.allCases.map { period in
                (selection.periodStyles[period] == .long ? period.longLabel : period.shortLabel,
                 period.shortLabel)
            }
        } ?? ["1ST", "2ND", "3RD", "4TH", "OT"].map { ($0, $0) }
        // OCR sometimes inserts a space between the quarter number and suffix.
        for label in ["1ST", "2ND", "3RD", "4TH"] where labels.contains(where: { $0.label == label }) {
            labels.append((String(label.prefix(1)) + " " + String(label.dropFirst()), label))
        }
        // Vision can substitute visually similar Cyrillic glyphs in short labels.
        if labels.contains(where: { $0.label == "4TH" }) {
            labels += [("4ТH", "4TH"), ("4ТН", "4TH")]
        }
        if labels.contains(where: { $0.label == "OT" }) {
            labels += [("ОT", "OT"), ("ОТ", "OT")]
        }
        guard let period = candidates.lazy.compactMap({ text -> String? in
            for (label, canonical) in labels {
                let escaped = NSRegularExpression.escapedPattern(for: label)
                    .replacingOccurrences(of: "\\ ", with: #"\s+"#)
                if text.range(of: "(?<![A-Z0-9])\(escaped)(?![A-Z0-9])",
                              options: .regularExpression) != nil { return canonical }
            }
            return nil
        }).first else { return nil }
        let clockPattern: String
        switch format?.underMinuteStyle {
        case .colon:
            clockPattern = #"(?:\d{1,2}:[0-5]\d|:[0-5]\d\.\d)"#
        case .natural:
            clockPattern = #"(?:\d{1,2}:[0-5]\d|(?:[1-5]\d|[0-9])\.\d)"#
        case .doubleDigit:
            clockPattern = #"(?:\d{1,2}:[0-5]\d|[0-5]\d\.\d)"#
        case nil:
            clockPattern = #"(?:\d{1,2}:\d{2}(?:\.\d+)?|:?\d{1,2}\.\d+)"#
        }
        guard let clockRegex = try? NSRegularExpression(
            pattern: "(?<![0-9:.])\(clockPattern)(?![0-9.])") else { return nil }
        var greatestUnderMinute: Double?
        for text in candidates {
            let matches = clockRegex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let parts = text[range].split(separator: ":", omittingEmptySubsequences: false)
                let secondsText = parts.count == 2 ? parts[1] : parts[0]
                guard let seconds = Double(secondsText), seconds < 60 else { continue }
                if parts.count == 2, let minutes = Int(parts[0]) {
                    return Reading(period: period, gameSecond: Double(minutes * 60) + seconds)
                }
                greatestUnderMinute = max(greatestUnderMinute ?? seconds, seconds)
            }
        }
        return greatestUnderMinute.map { Reading(period: period, gameSecond: $0) }
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
                    format: ScoreboardFormat? = nil,
                    recognize: Recognizer? = nil,
                    log: (String) -> Void = { _ in },
                    onSample: (Sample) -> Void = { _ in }) async throws -> [Entry] {
        let raw = try await sample(videoURL: videoURL, bottomDivisor: bottomDivisor,
                                   rightDivisor: rightDivisor, leftDivisor: leftDivisor,
                                   centerDivisor: centerDivisor, regionOfInterest: regionOfInterest,
                                   format: format,
                                   recognize: recognize, log: log, onSample: onSample)
        let entries = merge(raw)
        if let outputURL { try save(entries, to: outputURL) }
        return entries
    }

    static func sample(videoURL: URL, bottomDivisor: Int = 1,
                       rightDivisor: Int = 1, leftDivisor: Int = 1, centerDivisor: Int = 1,
                       regionOfInterest: CGRect? = nil,
                       format: ScoreboardFormat? = nil,
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
            let reading = parse(texts, format: format)
            let logLine = String(format: "%.1fs → %@ | OCR %@ | %.1f ms", sampleTime,
                       reading.map { "\($0.period) game clock \($0.gameSecond)s" } ?? "no clock or period detected",
                       texts.description, elapsed)
            log(logLine)
            let sample = Sample(id: samples.count, videoSecond: sampleTime,
                                reading: reading, ocrTexts: texts, logLine: logLine)
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
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
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
