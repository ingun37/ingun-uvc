import Foundation

struct ClockRange: Decodable, Sendable {
    let period: String
    let game_second: Double
    let start_seconds: Double
    let end_seconds: Double
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
    var included: Bool = true

    init(start: Double, end: Double, descriptions: [String]) {
        id = UUID()
        self.start = start
        self.end = end
        self.descriptions = descriptions
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
              ranges.allSatisfy({ $0.game_second.isFinite && $0.start_seconds.isFinite && $0.end_seconds.isFinite && $0.start_seconds >= 0 && $0.start_seconds < $0.end_seconds }) else {
            throw ClipPlanningError.invalidMapping
        }
        guard !attempts.isEmpty else { throw ClipPlanningError.noMisses }
        var candidates: [Clip] = []
        var unmatched: [String] = []
        for attempt in attempts {
            // The first game clock anchors a continuous, one-second-per-second range.
            // Keep the half-second tolerance for individually sampled readings.
            let matches = ranges.filter {
                $0.period.uppercased() == attempt.period &&
                clockDistance(attempt.gameSecond, in: $0) <= 0.51
            }
            guard let match = matches.min(by: {
                let left = clockDistance(attempt.gameSecond, in: $0)
                let right = clockDistance(attempt.gameSecond, in: $1)
                return left == right ? $0.start_seconds < $1.start_seconds : left < right
            }) else {
                unmatched.append("\(attempt.period) \(clockLabel(attempt.gameSecond)): \(attempt.description)")
                continue
            }
            let moment = min(max(match.start_seconds + min(max(match.game_second - attempt.gameSecond, 0),
                                                          match.end_seconds - match.start_seconds), 0), videoDuration)
            let start = max(0, moment - 5)
            let end = min(videoDuration, moment + 2)
            if end > start {
                candidates.append(Clip(start: start, end: end, descriptions: [attempt.description]))
            }
        }
        let sorted = candidates.sorted { $0.start < $1.start }
        var merged: [Clip] = []
        for clip in sorted {
            if let last = merged.indices.last, clip.start <= merged[last].end {
                merged[last].end = max(merged[last].end, clip.end)
                merged[last].descriptions += clip.descriptions
            } else {
                merged.append(clip)
            }
        }
        return ClipPlan(clips: merged, unmatched: unmatched)
    }

    private static func clockDistance(_ second: Double, in range: ClockRange) -> Double {
        let lowest = range.game_second - (range.end_seconds - range.start_seconds)
        return max(lowest - second, second - range.game_second, 0)
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
