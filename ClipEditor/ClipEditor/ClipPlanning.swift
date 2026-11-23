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
    let player: String?
    let shortName: String?
    let playerID: String?
    let caption: String?
    let location: CGPoint?

    init(period: String, gameSecond: Double, description: String, player: String? = nil,
         shortName: String? = nil,
         playerID: String? = nil, caption: String? = nil, location: CGPoint? = nil) {
        self.period = period
        self.gameSecond = gameSecond
        self.description = description
        self.player = player
        self.shortName = shortName
        self.playerID = playerID
        self.caption = caption
        self.location = location
    }
}

struct ShotCaption: Sendable {
    let sourceTime: Double
    let text: String
    let location: CGPoint?
    let player: String?
}

struct ClipAttempt: Sendable {
    let originalSourceTime: Double
    var sourceTime: Double
    let text: String?
    let location: CGPoint?
    let player: String?
    let shortName: String?
    let playerID: String?
    let shotDescription: String

    init(sourceTime: Double, text: String?, location: CGPoint?, player: String?,
         shortName: String? = nil,
         playerID: String? = nil, shotDescription: String = "") {
        originalSourceTime = sourceTime
        self.sourceTime = sourceTime
        self.text = text
        self.location = location
        self.player = player
        self.shortName = shortName
        self.playerID = playerID
        self.shotDescription = shotDescription
    }

    var caption: ShotCaption? {
        text.map { ShotCaption(sourceTime: sourceTime, text: $0, location: location, player: player) }
    }
}

struct CountEvent: Sendable {
    let made: Int
    let attempted: Int
    let isMade: Bool
    let gameTime: String?
}

struct PlayerFieldGoalStats: Sendable, Identifiable {
    let id: String
    let name: String
    let made: Int
    let attempted: Int

    var misses: Int { attempted - made }
    var percentage: Double { attempted == 0 ? 0 : Double(made) / Double(attempted) * 100 }

    static func exportedPlayers(_ keys: [String], countEvents: [String: [CountEvent]]) -> [Self] {
        keys.compactMap { key in
            guard let last = countEvents[key]?.last else { return nil }
            let name = String(key.split(separator: "|", maxSplits: 1,
                                        omittingEmptySubsequences: false).last ?? "")
            return Self(id: key, name: name, made: last.made, attempted: last.attempted)
        }
    }

    static func byMisses(_ stats: [Self]) -> [Self] {
        stats.sorted { left, right in
            if left.misses != right.misses { return left.misses > right.misses }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    static func byPercentage(_ stats: [Self]) -> [Self] {
        stats.sorted { left, right in
            let leftMade = left.made * right.attempted
            let rightMade = right.made * left.attempted
            if leftMade != rightMade { return leftMade < rightMade }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }
}

struct Clip: Identifiable, Sendable {
    let id: UUID
    let originalStart: Double
    var originalEnd: Double
    var start: Double
    var end: Double
    var descriptions: [String]
    var gameTimes: [String]
    var attempts: [ClipAttempt]
    var captions: [ShotCaption] { attempts.compactMap(\.caption) }
    var players: [String]
    var included: Bool = true

    init(start: Double, end: Double, descriptions: [String], gameTimes: [String] = [],
         captions: [ShotCaption] = [], attempts: [ClipAttempt] = [], players: [String] = []) {
        id = UUID()
        originalStart = start
        originalEnd = end
        self.start = start
        self.end = end
        self.descriptions = descriptions
        self.gameTimes = gameTimes
        self.attempts = attempts.isEmpty ? captions.map {
            ClipAttempt(sourceTime: $0.sourceTime, text: $0.text, location: $0.location, player: $0.player)
        } : attempts
        self.players = players
    }

    mutating func moveHandle(_ index: Int, to proposedTime: Double, moveAll: Bool, in range: ClosedRange<Double>) {
        guard (0...(attempts.count + 1)).contains(index), proposedTime.isFinite else { return }
        let current = index == 0 ? start : index == attempts.count + 1 ? end : attempts[index - 1].sourceTime
        if moveAll {
            let offset = min(max(proposedTime - current, range.lowerBound - start), range.upperBound - end)
            start += offset
            end += offset
            for attemptIndex in attempts.indices { attempts[attemptIndex].sourceTime += offset }
            return
        }
        let minimumLength = min(0.01, originalEnd - originalStart)
        if index == 0 {
            start = min(max(proposedTime, range.lowerBound), min(attempts.first?.sourceTime ?? end, end - minimumLength))
        } else if index == attempts.count + 1 {
            end = max(min(proposedTime, range.upperBound), max(attempts.last?.sourceTime ?? start, start + minimumLength))
        } else {
            let lower = index == 1 ? start : attempts[index - 2].sourceTime
            let upper = index == attempts.count ? end : attempts[index].sourceTime
            attempts[index - 1].sourceTime = min(max(proposedTime, lower), upper)
        }
    }

    mutating func resetTiming() {
        start = originalStart
        end = originalEnd
        for index in attempts.indices { attempts[index].sourceTime = attempts[index].originalSourceTime }
    }

    var timingIsOriginal: Bool {
        start == originalStart && end == originalEnd &&
        attempts.allSatisfy { $0.sourceTime == $0.originalSourceTime }
    }
}

struct ClipPlan: Sendable {
    let clips: [Clip]
    let unmatched: [String]
}

enum ClipPlanningError: LocalizedError {
    case missingColumns, malformedCSV, invalidClock(String), noMisses, invalidMapping(String)

    var errorDescription: String? {
        switch self {
        case .missingColumns: "The CSV must contain period, clock, result, and description columns."
        case .malformedCSV: "The CSV has an unterminated quoted field."
        case .invalidClock(let value): "Invalid game clock: \(value)"
        case .noMisses: "The CSV contains no missed field goals."
        case .invalidMapping(let detail): "Invalid mapping: \(detail)"
        }
    }
}

enum ClipPlanner {
    static func countEvents(from text: String) throws -> [String: [CountEvent]] {
        let rows = try csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              let resultIndex = header.firstIndex(of: "result"),
              let playerIndex = header.firstIndex(of: "player") else { return [:] }
        let fullNameIndex = header.firstIndex(of: "player_full_name")
        let teamIndex = header.firstIndex(of: "team")
        let periodIndex = header.firstIndex(of: "period")
        let clockIndex = header.firstIndex(of: "clock")
        var events: [String: [CountEvent]] = [:]
        for row in rows.dropFirst() {
            guard row.indices.contains(resultIndex), row.indices.contains(playerIndex) else { continue }
            let result = row[resultIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard result == "made" || result == "missed" else { continue }
            let player = row[playerIndex]
            let fullName = fullNameIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let team = teamIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let name = fullName.isEmpty ? player : fullName
            guard !name.isEmpty else { continue }
            let key = "\(team)|\(name)"
            let previous = events[key]?.last
            let period = periodIndex.flatMap { row.indices.contains($0) ? Int(row[$0].trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
            let seconds = clockIndex.flatMap { row.indices.contains($0) ? gameSeconds(row[$0].trimmingCharacters(in: .whitespacesAndNewlines)) : nil }
            let gameTime: String?
            if let period, period > 0, let seconds {
                let periodLabel = period == 5 ? "OT" : period > 5 ? "\(period - 4)OT" : "\(period)\(period == 1 ? "st" : period == 2 ? "nd" : period == 3 ? "rd" : "th")"
                let wholeSeconds = Int(seconds)
                gameTime = "\(periodLabel) \(wholeSeconds / 60)′\(wholeSeconds % 60)″"
            } else {
                gameTime = nil
            }
            events[key, default: []].append(CountEvent(made: (previous?.made ?? 0) + (result == "made" ? 1 : 0),
                                                         attempted: (previous?.attempted ?? 0) + 1,
                                                         isMade: result == "made", gameTime: gameTime))
        }
        return events
    }
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

    static func teams(from text: String) throws -> [String] {
        let rows = try csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              let teamIndex = header.firstIndex(of: "team") else { return [] }
        return Array(Set(rows.dropFirst().compactMap { row in
            row.indices.contains(teamIndex) ? row[teamIndex].trimmingCharacters(in: .whitespacesAndNewlines) : nil
        }.filter { !$0.isEmpty })).sorted()
    }

    static func attempts(from text: String) throws -> [MissedAttempt] {
        func shotDescription(_ raw: String, shortName: String) -> String {
            let description = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !shortName.isEmpty,
                  let prefix = description.range(of: "MISS \(shortName)",
                      options: [.anchored, .caseInsensitive, .diacriticInsensitive]),
                  let next = description[prefix.upperBound...].first, next.isWhitespace else {
                return description
            }
            let detail = description[prefix.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let distance = detail.range(
                of: #"^[0-9]+(?:\.[0-9]+)?['’′](?:\s+|$)"#,
                options: .regularExpression) else { return detail }
            return detail[distance.upperBound...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let rows = try csvRows(text)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
              let periodIndex = header.firstIndex(of: "period"),
              let clockIndex = header.firstIndex(of: "clock"),
              let resultIndex = header.firstIndex(of: "result"),
              let descriptionIndex = header.firstIndex(of: "description") else {
            throw ClipPlanningError.missingColumns
        }
        let playerIndex = header.firstIndex(of: "player")
        let playerIDIndex = header.firstIndex(of: "player_id")
        let fullNameIndex = header.firstIndex(of: "player_full_name")
        let jerseyIndex = header.firstIndex(of: "jersey_number")
        let teamIndex = header.firstIndex(of: "team")
        let xIndex = header.firstIndex(of: "loc_x")
        let yIndex = header.firstIndex(of: "loc_y")
        var totals: [String: (made: Int, attempted: Int)] = [:]
        return try rows.dropFirst().compactMap { row in
            guard row.count > max(periodIndex, clockIndex, resultIndex, descriptionIndex),
                  ["made", "missed"].contains(row[resultIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) else {
                return nil
            }
            let result = row[resultIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let player = (playerIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let playerID = playerIDIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let fullName = fullNameIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let jersey = jerseyIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let team = teamIndex.flatMap { row.indices.contains($0) ? row[$0] : nil } ?? ""
            let key = "\(team)|\(player)"
            if !player.isEmpty {
                var total = totals[key, default: (0, 0)]
                total.attempted += 1
                if result == "made" { total.made += 1 }
                totals[key] = total
            }
            guard result == "missed" else { return nil }
            let periodNumber = Int(row[periodIndex].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            let period = periodNumber == 5 ? "OT" : periodNumber > 5 ? "\(periodNumber - 4)OT" : "\(periodNumber)\(periodNumber == 1 ? "ST" : periodNumber == 2 ? "ND" : periodNumber == 3 ? "RD" : "TH")"
            let clock = row[clockIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard periodNumber >= 1, let seconds = gameSeconds(clock) else {
                throw ClipPlanningError.invalidClock(clock)
            }
            let x = xIndex.flatMap { row.indices.contains($0) ? Double(row[$0]) : nil }
            let y = yIndex.flatMap { row.indices.contains($0) ? Double(row[$0]) : nil }
            let location = (x?.isFinite == true && y?.isFinite == true) ? CGPoint(x: x!, y: y!) : nil
            let total = totals[key]
            let displayName = fullName.isEmpty ? player : fullName
            let identity = jersey.isEmpty ? displayName : "#\(jersey) \(displayName)"
            let caption = total.map { identity.isEmpty ? "\($0.made)/\($0.attempted)" : "\(identity)\n\($0.made)/\($0.attempted)" }
            return MissedAttempt(period: period, gameSecond: seconds,
                                 description: shotDescription(row[descriptionIndex], shortName: player),
                                 player: displayName.isEmpty ? nil : "\(team)|\(displayName)",
                                 shortName: player.isEmpty ? nil : player,
                                 playerID: playerID.isEmpty ? nil : playerID,
                                 caption: caption, location: location)
        }
    }

    static func plan(attempts: [MissedAttempt], ranges: [ClockRange], videoDuration: Double) throws -> ClipPlan {
        func invalidMapping(_ detail: String) -> ClipPlanningError {
            let error = ClipPlanningError.invalidMapping(detail)
            print(error.localizedDescription)
            return error
        }
        guard videoDuration.isFinite, videoDuration > 0 else {
            throw invalidMapping("source video duration must be finite and greater than zero (got \(videoDuration)).")
        }
        for (index, range) in ranges.enumerated() {
            let fields: [(String, Double)] = [
                ("game_start_seconds", range.game_start_seconds),
                ("game_end_seconds", range.game_end_seconds),
                ("video_start_seconds", range.video_start_seconds),
                ("video_end_seconds", range.video_end_seconds)
            ]
            if let (name, value) = fields.first(where: { !$0.1.isFinite }) {
                throw invalidMapping("entry \(index + 1) (period \(range.period)): \(name) must be finite (got \(value)).")
            }
            guard range.game_end_seconds >= 0, range.game_start_seconds >= range.game_end_seconds else {
                throw invalidMapping("entry \(index + 1) (period \(range.period)): game clock must decrease to a nonnegative value (start \(range.game_start_seconds), end \(range.game_end_seconds)).")
            }
            guard range.video_start_seconds >= 0, range.video_start_seconds < range.video_end_seconds else {
                throw invalidMapping("entry \(index + 1) (period \(range.period)): video range must have a nonnegative start before its end (start \(range.video_start_seconds), end \(range.video_end_seconds)).")
            }
        }
        guard !attempts.isEmpty else { throw ClipPlanningError.noMisses }
        let mappedRanges = ranges.map { MappedRange(range: $0) }
        var candidates: [Clip] = []
        var unmatched: [String] = []
        for attempt in attempts {
            let matches = mappedRanges.filter {
                $0.range.period.uppercased() == attempt.period &&
                $0.distance(to: attempt.gameSecond) <= 0.51
            }
            guard let match = matches.min(by: {
                let left = $0.distance(to: attempt.gameSecond)
                let right = $1.distance(to: attempt.gameSecond)
                return left == right ? $0.range.video_start_seconds < $1.range.video_start_seconds : left < right
            }) else {
                unmatched.append("\(attempt.period) \(clockLabel(attempt.gameSecond)): \(attempt.description)")
                continue
            }
            let moment = min(max(match.videoTime(for: attempt.gameSecond), 0), videoDuration)
            let start = max(0, moment - 4)
            let end = min(videoDuration, moment + 2)
            if end > start {
                let marker = ClipAttempt(sourceTime: moment, text: attempt.caption,
                                         location: attempt.location, player: attempt.player,
                                         shortName: attempt.shortName,
                                         playerID: attempt.playerID, shotDescription: attempt.description)
                candidates.append(Clip(start: start, end: end, descriptions: [attempt.description],
                                       gameTimes: ["\(attempt.period) \(clockLabel(attempt.gameSecond))"], attempts: [marker],
                                       players: attempt.player.map { [$0] } ?? []))
            }
        }
        let sorted = candidates.sorted { $0.start < $1.start }
        var merged: [Clip] = []
        for clip in sorted {
            if let last = merged.indices.last, clip.start <= merged[last].end {
                merged[last].end = max(merged[last].end, clip.end)
                merged[last].originalEnd = merged[last].end
                merged[last].descriptions += clip.descriptions
                merged[last].gameTimes += clip.gameTimes
                merged[last].attempts += clip.attempts
                for player in clip.players where !merged[last].players.contains(player) {
                    merged[last].players.append(player)
                }
            } else {
                merged.append(clip)
            }
        }
        return ClipPlan(clips: merged, unmatched: unmatched)
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

    static func csvRows(_ text: String) throws -> [[String]] {
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
