import AppKit
import SwiftUI

struct BoxScorePlayer: Identifiable, Sendable {
    let id: String
    let team: String
    let name: String
    let position: String
    let minutes: String
    let stats: [String: String]

    func value(_ key: String) -> String {
        if key == "minutes" {
            if minutes.hasPrefix("PT"), minutes.hasSuffix("S"),
               let separator = minutes.firstIndex(of: "M"),
               let wholeMinutes = Int(minutes[minutes.index(minutes.startIndex, offsetBy: 2)..<separator]),
               let seconds = Double(minutes[minutes.index(after: separator)..<minutes.index(before: minutes.endIndex)]) {
                return String(format: "%d:%02d", wholeMinutes, Int(seconds))
            }
            return minutes
        }
        let raw = stats[key] ?? ""
        if key.hasSuffix("Percentage"), let number = Double(raw) {
            return String(format: "%.1f%%", number * 100)
        }
        if key == "plusMinusPoints", let number = Double(raw) {
            return String(format: "%+.0f", number)
        }
        if let number = Double(raw) { return String(format: "%.0f", number) }
        return raw.isEmpty ? "–" : raw
    }

    func matches(_ key: String) -> Bool {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]).uppercased() == team.uppercased() else { return false }
        func normalized(_ name: String) -> String {
            name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                .filter { $0.isLetter || $0.isNumber }
        }
        return normalized(String(parts[1])) == normalized(name)
    }
}

struct BoxScore: Sendable {
    let players: [BoxScorePlayer]
    var teams: [String] { Array(Set(players.map(\.team))).sorted() }

    init(csv: String) throws {
        let rows = try ClipPlanner.csvRows(csv)
        guard let header = rows.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }),
              let teamIndex = header.firstIndex(of: "team"),
              let playerIndex = header.firstIndex(of: "player"),
              let minutesIndex = header.firstIndex(of: "minutes") else {
            throw BoxScoreError.invalidCSV
        }
        let positionIndex = header.firstIndex(of: "position")
        let commentIndex = header.firstIndex(of: "comment")
        players = rows.dropFirst().compactMap { row in
            guard row.count == header.count else { return nil }
            let minutes = row[minutesIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let comment = commentIndex.map { row[$0].trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard !minutes.isEmpty, comment.isEmpty else { return nil }
            let team = row[teamIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let name = row[playerIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !team.isEmpty, !name.isEmpty else { return nil }
            return BoxScorePlayer(id: "\(team)|\(name)", team: team, name: name,
                                  position: positionIndex.map { row[$0] } ?? "", minutes: minutes,
                                  stats: Dictionary(uniqueKeysWithValues: zip(header, row)))
        }
        guard !players.isEmpty else { throw BoxScoreError.noPlayers }
    }

    enum BoxScoreError: LocalizedError {
        case invalidCSV, noPlayers, playerMissing(String)
        var errorDescription: String? {
            switch self {
            case .invalidCSV: "The box score CSV needs team, player, and minutes columns."
            case .noPlayers: "The box score has no players who played."
            case .playerMissing(let name): "No box score row matches \(name)."
            }
        }
    }
}

struct BoxScoreColumn {
    let key: String
    let title: String
    let width: CGFloat
}

enum BoxScoreLayout {
    // Edit these arrays to change the columns or stats shown in the exported cards.
    static let compilationColumns: [BoxScoreColumn] = [
        .init(key: "minutes", title: "MIN", width: 72),
        .init(key: "points", title: "PTS", width: 58),
        .init(key: "reboundsTotal", title: "REB", width: 58),
        .init(key: "assists", title: "AST", width: 58),
        .init(key: "fieldGoalsMade", title: "FGM", width: 58),
        .init(key: "fieldGoalsAttempted", title: "FGA", width: 58),
        .init(key: "threePointersMade", title: "3PM", width: 58),
        .init(key: "threePointersAttempted", title: "3PA", width: 58),
        .init(key: "freeThrowsMade", title: "FTM", width: 58),
        .init(key: "freeThrowsAttempted", title: "FTA", width: 58),
    ]
    static let playerStats: [BoxScoreColumn] = [
        .init(key: "minutes", title: "Minutes", width: 0),
        .init(key: "points", title: "Points", width: 0),
        .init(key: "reboundsTotal", title: "Rebounds", width: 0),
        .init(key: "assists", title: "Assists", width: 0),
        .init(key: "steals", title: "Steals", width: 0),
        .init(key: "blocks", title: "Blocks", width: 0),
        .init(key: "turnovers", title: "Turnovers", width: 0),
        .init(key: "fieldGoalsMade", title: "Field goals made", width: 0),
        .init(key: "fieldGoalsAttempted", title: "Field goals attempted", width: 0),
        .init(key: "threePointersMade", title: "Three-pointers made", width: 0),
        .init(key: "threePointersAttempted", title: "Three-pointers attempted", width: 0),
        .init(key: "freeThrowsMade", title: "Free throws made", width: 0),
        .init(key: "freeThrowsAttempted", title: "Free throws attempted", width: 0),
        .init(key: "plusMinusPoints", title: "Plus/minus", width: 0),
    ]
}

struct CompilationBoxScoreView: View {
    let boxScore: BoxScore
    let date: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .firstTextBaseline) {
                Text("FINAL BOX SCORE").font(.system(size: 54, weight: .black))
                Spacer()
                if let date { Text(date).font(.system(size: 28, weight: .semibold)) }
            }
            HStack(alignment: .top, spacing: 26) {
                ForEach(boxScore.teams, id: \.self) { team in
                    teamTable(team)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(58)
        .foregroundStyle(.white)
        .frame(width: 1920, height: 1080)
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
    }

    private func teamTable(_ team: String) -> some View {
        let players = boxScore.players.filter { $0.team == team }
        return VStack(alignment: .leading, spacing: 12) {
            Text(team).font(.system(size: 40, weight: .bold))
            HStack(spacing: 4) {
                Text("PLAYER").frame(maxWidth: .infinity, alignment: .leading)
                ForEach(BoxScoreLayout.compilationColumns, id: \.key) { column in
                    Text(column.title).frame(width: column.width, alignment: .trailing)
                }
            }
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(.cyan)
            Rectangle().fill(.white.opacity(0.35)).frame(height: 1)
            ForEach(players) { player in
                HStack(spacing: 4) {
                    Text(player.name).lineLimit(1).minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(BoxScoreLayout.compilationColumns, id: \.key) { column in
                        Text(player.value(column.key))
                            .frame(width: column.width, alignment: .trailing)
                    }
                }
                .font(.system(size: 19, weight: .medium).monospacedDigit())
                .frame(height: 36)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct PlayerBoxScoreView: View {
    let player: BoxScorePlayer

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("FINAL BOX SCORE")
                .font(.system(size: 28, weight: .bold)).foregroundStyle(.cyan)
            Text(player.name)
                .font(.system(size: 58, weight: .black)).lineLimit(1).minimumScaleFactor(0.65)
            Text(player.team).font(.system(size: 28, weight: .semibold))
            Rectangle().fill(.white.opacity(0.4)).frame(height: 2)
            VStack(spacing: 0) {
                ForEach(Array(BoxScoreLayout.playerStats.enumerated()), id: \.offset) { index, stat in
                    HStack {
                        Text(stat.title).frame(maxWidth: .infinity, alignment: .leading)
                        Text(player.value(stat.key))
                            .monospacedDigit().frame(width: 170, alignment: .trailing)
                    }
                    .padding(.vertical, 8)
                    .background(index.isMultiple(of: 2) ? Color.white.opacity(0.06) : .clear)
                }
            }
            .font(.system(size: 30, weight: .medium))
            Spacer(minLength: 0)
        }
        .padding(70)
        .foregroundStyle(.white)
        .frame(width: 1080, height: 1080)
        .background(Color(red: 0.055, green: 0.075, blue: 0.12))
    }
}

#Preview("Compilation box score") {
    CompilationBoxScoreView(boxScore: .preview, date: "November 20, 2026")
        .scaleEffect(0.5).frame(width: 960, height: 540)
}

#Preview("Player box score") {
    PlayerBoxScoreView(player: BoxScore.preview.players[0])
        .scaleEffect(0.5).frame(width: 540, height: 540)
}

private extension BoxScore {
    static let preview = try! BoxScore(csv: """
    game_id,team,player_id,player,position,minutes,comment,points,reboundsTotal,assists,fieldGoalsMade,fieldGoalsAttempted,threePointersMade,threePointersAttempted,freeThrowsMade,freeThrowsAttempted,steals,blocks,turnovers,plusMinusPoints
    0022400061,BOS,1,Sample Guard,G,34:12,,28,5,8,10,19,4,9,4,5,2,1,3,12
    0022400061,BOS,2,Sample Forward,F,30:15,,17,9,3,7,14,1,4,2,2,1,0,2,8
    0022400061,LAL,3,Other Guard,G,36:44,,25,4,6,9,20,3,8,4,4,1,0,2,-5
    0022400061,LAL,4,Other Center,C,28:33,,14,12,2,6,11,0,0,2,3,0,2,1,-3
    """)
}
