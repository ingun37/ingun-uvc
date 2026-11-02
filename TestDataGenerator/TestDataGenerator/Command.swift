import AVFoundation
import Foundation

struct Mapping: Decodable {
    let period: String
    let game_start_seconds: Double
    let game_end_seconds: Double
    let video_start_seconds: Double
    let video_end_seconds: Double
}

struct Attempt {
    let row: Int
    let fields: [String: String]
    let period: String
    let gameSeconds: Double
}

struct Metadata: Encodable {
    let identifier: String
    let attempt: [String: String]
    let shot_time_seconds: Double
    let source_shot_time_seconds: Double
    let source_start_seconds: Double
    let source_end_seconds: Double
}

func rows(_ text: String) throws -> [[String]] {
    var result: [[String]] = []
    var row: [String] = []
    var field = ""
    var quoted = false
    let chars = Array(text.unicodeScalars)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if quoted {
            if c == "\"" {
                if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                else { quoted = false }
            } else { field.unicodeScalars.append(c) }
        } else {
            switch c {
            case "\"" where field.isEmpty: quoted = true
            case ",": row.append(field); field = ""
            case "\n", "\r":
                row.append(field)
                if row.contains(where: { !$0.isEmpty }) { result.append(row) }
                row = []; field = ""
                if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            default: field.unicodeScalars.append(c)
            }
        }
        i += 1
    }
    guard !quoted else { throw ToolError.message("Unterminated quoted CSV field") }
    if !row.isEmpty || !field.isEmpty { row.append(field); result.append(row) }
    return result
}

func gameSeconds(_ clock: String) -> Double? {
    let pattern = #"^PT(?:(\d+)M)?(\d+(?:\.\d+)?)S$"#
    guard let match = clock.uppercased().range(of: pattern, options: .regularExpression) else { return nil }
    let parts = String(clock[match]).uppercased().dropFirst(2).dropLast().split(separator: "M")
    if parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]) { return minutes * 60 + seconds }
    return parts.count == 1 ? Double(parts[0]) : nil
}

func periodLabel(_ number: Int) -> String {
    if number == 5 { return "OT" }
    if number > 5 { return "\(number - 4)OT" }
    return "\(number)\(["ST", "ND", "RD", "TH"][min(number - 1, 3)])"
}

func attempts(_ text: String) throws -> [Attempt] {
    let parsed = try rows(text)
    guard let header = parsed.first?.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }),
          let periodIndex = header.firstIndex(of: "period"), let clockIndex = header.firstIndex(of: "clock") else {
        throw ToolError.message("CSV must contain period and clock columns")
    }
    return try parsed.dropFirst().enumerated().map { offset, row in
        guard row.count == header.count, let period = Int(row[periodIndex].trimmingCharacters(in: .whitespaces)), period > 0,
              let seconds = gameSeconds(row[clockIndex].trimmingCharacters(in: .whitespaces)) else {
            throw ToolError.message("Invalid attempt on CSV row \(offset + 2)")
        }
        return Attempt(row: offset + 2, fields: Dictionary(uniqueKeysWithValues: zip(header, row)),
                       period: periodLabel(period), gameSeconds: seconds)
    }
}

enum ToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

func export(videoTrack: AVAssetTrack, audioTrack: AVAssetTrack?, start: Double, end: Double, destination: URL) async throws {
    let composition = AVMutableComposition()
    guard let outputVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
        throw ToolError.message("Could not create video track")
    }
    let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                            end: CMTime(seconds: end, preferredTimescale: 600))
    try outputVideo.insertTimeRange(range, of: videoTrack, at: .zero)
    outputVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
    if let audioTrack {
        guard let outputAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ToolError.message("Could not create audio track")
        }
        try outputAudio.insertTimeRange(range, of: audioTrack, at: .zero)
    }
    guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
        throw ToolError.message("Could not create export session")
    }
    try await session.export(to: destination, as: .mp4)
}

@main struct Command {
    static func main() async {
        do { try await run() }
        catch { fputs("Error: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 4 else {
            throw ToolError.message("Usage: TestDataGenerator VIDEO MAPPING_JSON ATTEMPTS_CSV OUTPUT_DIR [--window SECONDS] [--before SECONDS] [--after SECONDS]")
        }
        var before = 3.0
        var after = 3.0
        var optionIndex = 4
        while optionIndex < args.count {
            guard optionIndex + 1 < args.count, let value = Double(args[optionIndex + 1]),
                  value.isFinite, value >= 0 else { throw ToolError.message("Invalid window duration") }
            switch args[optionIndex] {
            case "--before": before = value
            case "--after": after = value
            case "--window": before = value; after = value
            default: throw ToolError.message("Unknown option \(args[optionIndex])")
            }
            optionIndex += 2
        }
        let video = URL(fileURLWithPath: args[0])
        let output = URL(fileURLWithPath: args[3], isDirectory: true)
        let mappings = try JSONDecoder().decode([Mapping].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
        let attempts = try attempts(String(contentsOfFile: args[2], encoding: .utf8))
        guard mappings.allSatisfy({ $0.game_start_seconds.isFinite && $0.game_end_seconds.isFinite &&
            $0.game_start_seconds >= $0.game_end_seconds && $0.game_end_seconds >= 0 &&
            $0.video_start_seconds.isFinite && $0.video_end_seconds.isFinite &&
            $0.video_start_seconds >= 0 && $0.video_start_seconds < $0.video_end_seconds }) else {
            throw ToolError.message("Mapping contains invalid ranges")
        }
        let asset = AVURLAsset(url: video)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError.message("No video track") }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite && duration > 0 else { throw ToolError.message("Invalid video duration") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var exported = 0
        var skipped = 0
        for attempt in attempts {
            let matches = mappings.enumerated().compactMap { index, range -> (Int, Mapping, Double)? in
                guard range.period.uppercased() == attempt.period else { return nil }
                let distance = max(range.game_end_seconds - attempt.gameSeconds,
                                   attempt.gameSeconds - range.game_start_seconds, 0)
                return distance <= 0.51 ? (index, range, distance) : nil
            }
            guard let selected = matches.min(by: { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 < $1.2 }) else {
                skipped += 1; continue
            }
            let range = selected.1
            let clockSpan = range.game_start_seconds - range.game_end_seconds
            let fraction = clockSpan > 0 ? min(max((range.game_start_seconds - attempt.gameSeconds) / clockSpan, 0), 1) : 0
            let moment = min(max(range.video_start_seconds + fraction * (range.video_end_seconds - range.video_start_seconds), 0), duration)
            let start = max(0, moment - before)
            let end = min(duration, moment + after)
            guard end > start else { skipped += 1; continue }
            let identifier = String(format: "attempt-%04d", attempt.row - 1)
            let clipURL = output.appendingPathComponent(identifier + ".mp4")
            let metadataURL = output.appendingPathComponent(identifier + ".json")
            let staged = output.appendingPathComponent(".\(identifier)-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: staged) }
            try await export(videoTrack: videoTrack, audioTrack: audioTrack, start: start, end: end, destination: staged)
            let metadata = Metadata(identifier: identifier, attempt: attempt.fields,
                                    shot_time_seconds: moment - start, source_shot_time_seconds: moment,
                                    source_start_seconds: start, source_end_seconds: end)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(metadata)
            if FileManager.default.fileExists(atPath: clipURL.path) { try FileManager.default.removeItem(at: clipURL) }
            try FileManager.default.moveItem(at: staged, to: clipURL)
            try data.write(to: metadataURL, options: .atomic)
            exported += 1
        }
        print("Exported \(exported) attempts; skipped \(skipped) without a usable mapping.")
    }
}
