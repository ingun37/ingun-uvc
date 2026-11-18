import CoreVideo
import Foundation
import Vision

/// Reads the period and remaining game-clock seconds from one decoded video frame.
nonisolated enum GameTimeReader {
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
            case .firstOvertime: "OT"
            case .secondOvertime: "2OT"
            case .thirdOvertime: "3OT"
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

    static func parse(_ texts: [String], format: ScoreboardFormat? = nil) -> Reading? {
        func normalizedClockText(_ text: String) -> String {
            text.uppercased()
                .replacingOccurrences(of: #"(?<![\d.])(\d{1,2})\s*:\s*(?=\d)"#,
                                      with: "$1:", options: .regularExpression)
                .replacingOccurrences(of: #":\s+(?=\d)"#, with: ":", options: .regularExpression)
                // Vision occasionally splits the last second digit: "5:5 1" -> "5:51".
                .replacingOccurrences(of: #"(?<!\w)(\d):(\d)\s+(\d)(?!\w)"#,
                                      with: "$1:$2$3", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=\d)\s*\.\s*(?=\d)"#, with: ".", options: .regularExpression)
                // Vision can also split a sub-minute clock: ":0 1.5" -> ":01.5".
                .replacingOccurrences(of: #"(?<!\w):(\d)\s+(\d)\.(\d)(?!\w)"#,
                                      with: ":$1$2.$3", options: .regularExpression)
                .replacingOccurrences(of: #"(?<=:[0-5])Б(?![\p{L}0-9])"#,
                                      with: "6", options: .regularExpression)
        }
        let normalized = texts.map(normalizedClockText)
        let combined = normalizedClockText(texts.joined(separator: " "))
        let candidates = normalized + [combined]
        let labels = periodLabels(format: format)
        guard let period = candidates.lazy.compactMap({ text -> String? in
            labels.first { periodLabel($0.label, matches: text) }?.canonical
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

    private static func periodLabels(format: ScoreboardFormat?) -> [(label: String, canonical: String)] {
        var labels: [(label: String, canonical: String)] = format.map { selection in
            Period.allCases.map { period in
                (selection.periodStyles[period] == .long ? period.longLabel : period.shortLabel,
                 period.shortLabel)
            }
        } ?? Period.allCases.map { ($0.shortLabel, $0.shortLabel) }
        // OCR sometimes inserts a space between the quarter number and suffix.
        for label in ["1ST", "2ND", "3RD", "4TH"] where labels.contains(where: { $0.label == label }) {
            labels.append((String(label.prefix(1)) + " " + String(label.dropFirst()), label))
        }
        if labels.contains(where: { $0.label == "1ST" }) {
            labels += [("IST", "1ST"), ("15T", "1ST"), ("I5T", "1ST")]
        }
        if labels.contains(where: { $0.label == "2ND" }) {
            labels += [("ZND", "2ND")]
        }
        if labels.contains(where: { $0.label == "3RD" }) {
            labels += [("3ED", "3RD"), ("38D", "3RD"), ("3AD", "3RD"), ("ЗRD", "3RD"), ("ЭRD", "3RD")] // The last 3RD is Cyrillic З (U+0417)
        }
        // Vision can substitute visually similar Cyrillic glyphs in short labels.
        if labels.contains(where: { $0.label == "4TH" }) {
            labels += [("4ТH", "4TH"), ("4ТН", "4TH"), ("4Tн", "4TH"), ("4Тн", "4TH")]
        }
        if labels.contains(where: { $0.label == "OT" }) {
            labels += [("ОT", "OT"), ("ОТ", "OT")]
        }
        // Vision can read the letter O as zero in numbered overtime labels.
        if labels.contains(where: { $0.label == "2OT" }) {
            labels.append(("20T", "2OT"))
        }
        if labels.contains(where: { $0.label == "3OT" }) {
            labels.append(("30T", "3OT"))
        }
        return labels
    }

    private static func periodLabel(_ label: String, matches text: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: label)
            .replacingOccurrences(of: "\\ ", with: #"\s+"#)
        return text.uppercased().range(of: "(?<![A-Z0-9])\(escaped)(?![A-Z0-9])",
                                     options: .regularExpression) != nil
    }

    static func preferredCandidateIndex(_ texts: [String], format: ScoreboardFormat) -> Int? {
        guard !texts.isEmpty else { return nil }
        let labels = periodLabels(format: format)
        return texts.firstIndex { text in labels.contains { periodLabel($0.label, matches: text) } } ?? 0
    }

    static func read(_ buffer: CVPixelBuffer, format: ScoreboardFormat,
                     regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) throws -> Reading? {
        try readWithTexts(buffer, format: format, regionOfInterest: regionOfInterest).reading
    }

    static func readWithTexts(_ buffer: CVPixelBuffer, format: ScoreboardFormat,
                              regionOfInterest: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1))
        throws -> (reading: Reading?, texts: [String]) {
        let texts = try visionTexts(buffer, format: format, regionOfInterest: regionOfInterest)
        return (parse(texts, format: format), texts)
    }

    private static func visionTexts(_ buffer: CVPixelBuffer, format: ScoreboardFormat,
                                    regionOfInterest: CGRect) throws -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false
        request.regionOfInterest = regionOfInterest
        try VNImageRequestHandler(cvPixelBuffer: buffer).perform([request])
        return (request.results ?? []).compactMap { observation -> VNRecognizedText? in
            let candidates = observation.topCandidates(10)
            guard let index = preferredCandidateIndex(candidates.map(\.string), format: format) else {
                return nil
            }
            return candidates[index]
        }
            .filter { $0.confidence >= 0.5 }.map(\.string)
    }

}
