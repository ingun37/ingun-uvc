import AppKit
import Foundation
import Observation

struct ShotEffectKey: Hashable {
    let clipID: UUID
    let attemptIndex: Int
}

struct AppliedShotEffect: Sendable {
    let timestamp: Double
    let bounds: CGRect
    let frameSize: CGSize
    let maskPNG: Data
    let maskPixels: Data
    let playerID: String?
    let playerName: String
    let shotDescription: String
    let shotLocation: CGPoint?
}

struct PreparedShotEffect: Sendable {
    let effect: AppliedShotEffect
    let stats: LocalShotStats
}

enum ShotEffectArea {
    static let highlightColor = NSColor(srgbRed: 1, green: 229.0 / 255.0,
                                        blue: 28.0 / 255.0, alpha: 1)

    // Coordinates match the displayed frame: the origin is at its top-left.
    static func ellipse(atBottomOf bounds: CGRect, in frameSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0 else { return .zero }
        let width = min(frameSize.width, max(24, bounds.width * 1.25))
        let height = min(frameSize.height, max(8, width * 0.22))
        let centerX = min(max(bounds.midX, width / 2), frameSize.width - width / 2)
        let centerY = min(max(bounds.maxY, height / 2), frameSize.height - height / 2)
        return CGRect(x: centerX - width / 2, y: centerY - height / 2,
                      width: width, height: height)
    }

    static func resized(_ bounds: CGRect, to size: CGSize, in frameSize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0,
              size.width.isFinite, size.height.isFinite else { return bounds }
        let width = min(max(1, size.width), frameSize.width)
        let height = min(max(1, size.height), frameSize.height)
        let x = min(max(0, bounds.midX - width / 2), frameSize.width - width)
        let y = min(max(0, bounds.midY - height / 2), frameSize.height - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

@MainActor @Observable
final class ShotEffectStore {
    var effects: [ShotEffectKey: AppliedShotEffect] = [:]
}

struct LocalShotStats: Equatable {
    let makes: Int
    let attempts: Int

    var percent: Int { attempts == 0 ? 0 : Int((Double(makes) / Double(attempts) * 100).rounded()) }

    static func near(_ location: CGPoint, in csv: String) throws -> Self {
        let rows = try ClipPlanner.csvRows(csv)
        guard let header = rows.first?.map({ $0.lowercased() }),
              let xIndex = header.firstIndex(of: "loc_x"),
              let yIndex = header.firstIndex(of: "loc_y"),
              let resultIndex = header.firstIndex(of: "result") else {
            throw ShotEffectError.invalidCSV
        }
        var makes = 0
        var attempts = 0
        for row in rows.dropFirst() {
            guard row.indices.contains(max(xIndex, yIndex, resultIndex)),
                  let x = Double(row[xIndex]), let y = Double(row[yIndex]),
                  x.isFinite, y.isFinite,
                  hypot(x - location.x, y - location.y) <= 20 else { continue }
            attempts += 1
            if row[resultIndex].lowercased() == "made" { makes += 1 }
        }
        return Self(makes: makes, attempts: attempts)
    }
}

enum ShotEffectError: LocalizedError {
    case invalidCSV, missingDate, missingPlayerID, missingShotLocation, missingFetcher, fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCSV: "The player-attempts CSV is missing required columns."
        case .missingDate: "The game date could not be determined."
        case .missingPlayerID: "The attempt has no NBA player ID."
        case .missingShotLocation: "The attempt has no court location."
        case .missingFetcher: "The data_fetcher executable could not be found."
        case .fetchFailed(let detail): "The player-attempts fetch failed: \(detail)"
        }
    }
}

enum PlayerAttemptFetcher {
    static func inputGameDate(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
            return nil
        }
        return value
    }

    static func gameDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        for format in ["yyyy-MM-dd", "MMM d, yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    static func fetch(playerID: String, gameDate: Date) async throws -> String {
        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let start = utc.date(byAdding: .year, value: -1, to: gameDate),
              let end = utc.date(byAdding: .day, value: -1, to: gameDate) else {
            throw ShotEffectError.missingDate
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let startText = formatter.string(from: start)
        let endText = formatter.string(from: end)
        return try await Task.detached(priority: .userInitiated) {
            let manager = FileManager.default
            var root = URL(fileURLWithPath: manager.currentDirectoryPath)
            let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent()
            let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
            let candidates = [root, bundleParent, bundleParent.deletingLastPathComponent(),
                              bundleParent.deletingLastPathComponent().deletingLastPathComponent(), sourceRoot]
            guard let projectRoot = candidates.first(where: {
                manager.fileExists(atPath: $0.appending(path: "data_fetcher/main.py").path)
            }) else { throw ShotEffectError.missingFetcher }
            root = projectRoot
            let python = root.appending(path: "data_fetcher/.venv/bin/python")
            let binary = root.appending(path: "data_fetcher/dist/main")
            let process = Process()
            if manager.isExecutableFile(atPath: python.path) {
                process.executableURL = python
                process.arguments = [root.appending(path: "data_fetcher/main.py").path]
            } else if manager.isExecutableFile(atPath: binary.path) {
                process.executableURL = binary
                process.arguments = []
            } else {
                throw ShotEffectError.missingFetcher
            }
            let output = manager.temporaryDirectory.appending(path: "player-shots-\(UUID().uuidString).csv")
            let error = manager.temporaryDirectory.appending(path: "player-shots-\(UUID().uuidString).log")
            manager.createFile(atPath: error.path, contents: nil)
            defer {
                try? manager.removeItem(at: output)
                try? manager.removeItem(at: error)
            }
            process.arguments! += ["player-attempts", playerID, startText, endText, "--output", output.path]
            process.standardOutput = FileHandle.nullDevice
            let errorHandle = try FileHandle(forWritingTo: error)
            defer { try? errorHandle.close() }
            process.standardError = errorHandle
            do {
                try process.run()
            } catch {
                throw ShotEffectError.fetchFailed("Could not launch \(process.executableURL?.path ?? "data_fetcher"): \(error.localizedDescription)")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = ((try? String(contentsOf: error, encoding: .utf8)) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw ShotEffectError.fetchFailed(detail.isEmpty ? "exit status \(process.terminationStatus)" : detail)
            }
            do {
                return try String(contentsOf: output, encoding: .utf8)
            } catch {
                throw ShotEffectError.fetchFailed("The command exited successfully but its CSV could not be read: \(error.localizedDescription)")
            }
        }.value
    }
}
