import Foundation
import Testing

struct GametimeMapperTests {
    @Test func mergesOnlyContinuousClockAndVideoTime() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 100), at: 0, until: 1, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 99), at: 1, until: 2, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 98), at: 3, until: 4, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 96), at: 4, until: 5, to: &entries)
        #expect(entries.map(\.game_second) == [100, 98, 96])
        #expect(entries[0].end_seconds == 2)
    }

    @Test func mergesShortGapsWhenClockRemainsContinuous() {
        var entries: [GameTimeMapper.Entry] = []
        for (clock, start, end) in [(116.0, 69.0, 81.0), (103, 82, 85),
                                    (100, 85.5, 100.5), (84, 101, 126)] {
            GameTimeMapper.add(.init(period: "2ND", gameSecond: clock),
                               at: start, until: end, to: &entries)
        }
        #expect(entries == [.init(period: "2ND", game_second: 116,
                                  start_seconds: 69, end_seconds: 126)])
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 82), at: 128, until: 129, to: &entries)
        #expect(entries.count == 2)
    }

    @Test func mergesWholeSecondToFractionalClockTransition() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 116), at: 69, until: 126, to: &entries)
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 59.8), at: 126, until: 145, to: &entries)
        #expect(entries == [.init(period: "2ND", game_second: 116,
                                  start_seconds: 69, end_seconds: 145)])
    }
    @Test func parsesPeriodAndClock() {
        #expect(GameTimeMapper.parse(["1ST", "07:20"]) == .init(period: "1ST", gameSecond: 440))
        #expect(GameTimeMapper.parse(["2ND 00:59.9"]) == .init(period: "2ND", gameSecond: 59.9))
        #expect(GameTimeMapper.parse(["3RD", ":06.1"]) == .init(period: "3RD", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["4TH", "07", ":", "20"]) == .init(period: "4TH", gameSecond: 440))
        #expect(GameTimeMapper.parse(["OT", "00:00"]) == .init(period: "OT", gameSecond: 0))
        #expect(GameTimeMapper.parse(["nGS", "SAC : 34 2ND 1:57 24 67 SAS", "SAC", "34", "67", "SAS"]) == .init(period: "2ND", gameSecond: 117))
        #expect(GameTimeMapper.parse(["SAC : 34 1:57 2ND 24 67 SAS"]) == .init(period: "2ND", gameSecond: 117))
        #expect(GameTimeMapper.parse(["SAC : 34 2ND 24"]) == nil)
        #expect(GameTimeMapper.parse(["5TH", "07:20"]) == nil)
        #expect(GameTimeMapper.parse(["OT", "07:60"]) == nil)
    }

    @Test(arguments: ["minutes-seconds.mp4", "seconds-fractional.mp4"])
    func mapsBundledVideo(_ name: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/\(name)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output, recognize: { _ in
            ["1ST", name == "minutes-seconds.mp4" ? "07:20" : ":06.1"]
        })
        #expect(!entries.isEmpty)
        #expect(entries.allSatisfy { $0.period == "1ST" && $0.start_seconds < $0.end_seconds })
        #expect(entries.first?.game_second == (name == "minutes-seconds.mp4" ? 440 : 6.1))
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }

    @Test func mapsUncroppedBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-only.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries.map(\.game_second) == [442])
        #expect(entries.allSatisfy { $0.period == "2ND" })
        #expect(entries.first?.start_seconds == 0)
        #expect(entries.last?.end_seconds == 3)
    }

    @Test func mapsBottomHalfOfBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-only.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output, bottomDivisor: 2)
        #expect(entries.map(\.game_second) == [442])
        #expect(entries.allSatisfy { $0.period == "2ND" })
        #expect(entries.first?.start_seconds == 0)
        #expect(entries.last?.end_seconds == 3)
    }

    @Test func mapsFractionalBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-including-fractional.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries.map(\.game_second) == [62])
        #expect(entries.allSatisfy { $0.period == "2ND" })
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }

    @Test func leavesGapUntilThirdQuarterScoreboardAppears() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/not-continuous.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries.first?.start_seconds == 2.5)
        #expect(entries.map(\.game_second) == [718])
        #expect(entries.allSatisfy { $0.period == "3RD" })
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }
}
