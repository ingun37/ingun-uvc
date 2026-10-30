import Foundation

struct ClockRange: Decodable, Sendable {
    let period: String
    let game_start_seconds: Double
    let game_end_seconds: Double
    let video_start_seconds: Double
    let video_end_seconds: Double
}

struct MissedAttempt: Sendable {
    let period: String
    let gameSecond: Double
    let description: String
}

struct Clip: Identifiable, Sendable {
    let id: UUID
    var start: Double
    var end: Double
    var descriptions: [String]
    var gameTimes: [String]
    var included: Bool = true

    init(start: Double, end: Double, descriptions: [String], gameTimes: [String] = []) {
        id = UUID()
        self.start = start
        self.end = end
        self.descriptions = descriptions
        self.gameTimes = gameTimes
    }
}

struct ClipPlan: Sendable {
    let clips: [Clip]
    let unmatched: [String]
}

enum ClipPlanningError: LocalizedError {
    case missingColumns, malformedCSV, invalidClock(String), noMisses, invalidMapping

    var errorDescription: String? {
        switch self {
        case .missingColumns: "The CSV must contain period, clock, result, and description columns."
        case .malformedCSV: "The CSV has an unterminated quoted field."
        case .invalidClock(let value): "Invalid game clock: \(value)"
        case .noMisses: "The CSV contains no missed field goals."
        case .invalidMapping: "The mapping JSON contains invalid video ranges."
        }
    }
}

enum ClipPlanner {
    private struct MappedRange {
        let range: ClockRange
        var clockDuration: Double { range.game_start_seconds - range.game_end_seconds }
        var videoDuration: Double { range.video_end_seconds - range.video_start_seconds }

        func distance(to second: Double) -> Double {
            max(range.game_end_seconds - second, second - range.game_start_seconds, 0)
        }

        func videoTime(for second: Double) -> Double {
            guard clockDuration > 0 else { return range.video_start_seconds }
            let fraction = min(max((range.game_start_seconds - second) / clockDuration, 0), 1)
            return range.video_start_seconds + fraction * videoDuration
        }
    }

    static func attempts(from text: String) throws -> [MissedAttempt] {
        let rows = try csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              let periodIndex = header.firstIndex(of: "period"),
              let clockIndex = header.firstIndex(of: "clock"),
              let resultIndex = header.firstIndex(of: "result"),
              let descriptionIndex = header.firstIndex(of: "description") else {
            throw ClipPlanningError.missingColumns
        }
        return try rows.dropFirst().compactMap { row in
            guard row.count > max(periodIndex, clockIndex, resultIndex, descriptionIndex),
                  row[resultIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "missed" else {
                return nil
            }
            let periodNumber = Int(row[periodIndex].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let period = periodNumber == 5 ? "OT" : periodNumber > 5 ? "\(periodNumber - 4)OT" : "\(periodNumber)\(periodNumber == 1 ? "ST" : periodNumber == 2 ? "ND" : periodNumber == 3 ? "RD" : "TH")"
            let clock = row[clockIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard periodNumber >= 1, let seconds = gameSeconds(clock) else {
                throw ClipPlanningError.invalidClock(clock)
            }
            return MissedAttempt(period: period, gameSecond: seconds, description: row[descriptionIndex])
        }
    }

    static func plan(attempts: [MissedAttempt], ranges: [ClockRange], videoDuration: Double) throws -> ClipPlan {
        guard videoDuration.isFinite, videoDuration > 0,
              ranges.allSatisfy({ $0.game_start_seconds.isFinite && $0.game_end_seconds.isFinite &&
                  $0.game_start_seconds >= $0.game_end_seconds && $0.game_end_seconds >= 0 &&
                  $0.video_start_seconds.isFinite && $0.video_end_seconds.isFinite &&
                  $0.video_start_seconds >= 0 && $0.video_start_seconds < $0.video_end_seconds }) else {
            throw ClipPlanningError.invalidMapping
        }
        guard !attempts.isEmpty else { throw ClipPlanningError.noMisses }
        let mappedRanges = ranges.map { MappedRange(range: $0) }
        var candidates: [Clip] = []
        var unmatched: [String] = []
        for attempt in attempts {
            let matches = mappedRanges.filter {
                $0.range.period.uppercased() == attempt.period &&
                $0.clockDuration > 0 &&
                $0.distance(to: attempt.gameSecond) <= 0.51
            }
            guard let match = matches.min(by: {
                let left = $0.distance(to: attempt.gameSecond)
                let right = $1.distance(to: attempt.gameSecond)
                return left == right ? $0.range.video_start_seconds < $1.range.video_start_seconds : left < right
            }) else {
                if !mappedRanges.contains(where: { $0.range.period.uppercased() == attempt.period &&
                    $0.clockDuration == 0 && $0.distance(to: attempt.gameSecond) <= 0.51 }) {
                    unmatched.append("\(attempt.period) \(clockLabel(attempt.gameSecond)): \(attempt.description)")
                }
                continue
            }
            let moment = min(max(match.videoTime(for: attempt.gameSecond), 0), videoDuration)
            let start = moment - 5
            let end = moment + 2
            if start >= 0, end <= videoDuration,
               coversVideo(start: start, end: end, period: attempt.period, ranges: ranges) {
                candidates.append(Clip(start: start, end: end, descriptions: [attempt.description],
                                       gameTimes: ["\(attempt.period) \(clockLabel(attempt.gameSecond))"]))
            }
        }
        let sorted = candidates.sorted { $0.start < $1.start }
        var merged: [Clip] = []
        for clip in sorted {
            if let last = merged.indices.last, clip.start <= merged[last].end {
                merged[last].end = max(merged[last].end, clip.end)
                merged[last].descriptions += clip.descriptions
                merged[last].gameTimes += clip.gameTimes
            } else {
                merged.append(clip)
            }
        }
        return ClipPlan(clips: merged, unmatched: unmatched)
    }

    private static func coversVideo(start: Double, end: Double, period: String, ranges: [ClockRange]) -> Bool {
        var coveredUntil = start
        for range in ranges.sorted(by: { $0.video_start_seconds < $1.video_start_seconds })
            where range.period.uppercased() == period {
            if range.video_end_seconds <= coveredUntil { continue }
            if range.video_start_seconds > coveredUntil + 0.000001 { return false }
            coveredUntil = range.video_end_seconds
            if coveredUntil >= end - 0.000001 { return true }
        }
        return false
    }

    static func clockLabel(_ seconds: Double) -> String {
        String(format: "%02d:%05.2f", Int(seconds) / 60, seconds.truncatingRemainder(dividingBy: 60))
    }

    private static func gameSeconds(_ value: String) -> Double? {
        let pattern = #"^PT(?:(\d+)M)?(\d+(?:\.\d+)?)S$"#
        guard let match = value.uppercased().range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(value[match]).uppercased().dropFirst(2).dropLast()
        let components = matched.split(separator: "M")
        if components.count == 2, let minutes = Double(components[0]), let seconds = Double(components[1]) {
            return minutes * 60 + seconds
        }
        return components.count == 1 ? Double(components[0]) : nil
    }

    private static func csvRows(_ text: String) throws -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text.unicodeScalars)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if quoted {
                if character == "\"" {
                    if index + 1 < characters.count && characters[index + 1] == "\"" {
                        field.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(character)
                }
            } else {
                switch character {
                case "\"" where field.isEmpty: quoted = true
                case ",": row.append(field); field = ""
                case "\n":
                    row.append(field)
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []; field = ""
                case "\r":
                    row.append(field)
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []; field = ""
                default: field.unicodeScalars.append(character)
                }
            }
            index += 1
        }
        guard !quoted else { throw ClipPlanningError.malformedCSV }
        if !row.isEmpty || !field.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
