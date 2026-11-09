import AVFoundation
import Foundation
import Testing

struct GametimeMapperTests {
    @Test func retainsReadingsUntilExplicitMerge() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/minutes-seconds.mp4")
        let raw = try await GameTimeMapper.sample(videoURL: video, recognize: { _ in ["1ST", "07:20"] })
        #expect(raw.samples.count > 1)
        #expect(raw.samples.allSatisfy { $0.reading?.gameSecond == 440 })
        let merged = GameTimeMapper.merge(raw)
        #expect(merged.count < raw.samples.count)
        #expect(merged.first?.game_start_seconds == 440)
    }

    @Test func removesOutlierBeforeMerge() {
        let samples = [
            GameTimeMapper.Sample(id: 0, videoSecond: 0,
                                  reading: .init(period: "1ST", gameSecond: 100),
                                  ocrTexts: ["1ST", "1:40"], logLine: "first"),
            GameTimeMapper.Sample(id: 1, videoSecond: 0.5,
                                  reading: .init(period: "1ST", gameSecond: 500),
                                  ocrTexts: ["1ST", "8:20"], logLine: "outlier"),
            GameTimeMapper.Sample(id: 2, videoSecond: 1,
                                  reading: .init(period: "1ST", gameSecond: 99),
                                  ocrTexts: ["1ST", "1:39"], logLine: "last")
        ]
        let raw = GameTimeMapper.RawReadings(samples: samples, duration: 1.5)
        #expect(GameTimeMapper.merge(raw).count == 3)
        let filtered = raw.removingSample(id: 1)
        #expect(filtered.samples.map(\.id) == [0, 2])
        #expect(GameTimeMapper.merge(filtered) == [
            .init(period: "1ST", game_start_seconds: 100, game_end_seconds: 99,
                  video_start_seconds: 0, video_end_seconds: 1.5)
        ])
    }

    @Test func cropsFromRightAndBottomTogether() {
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 1, rightDivisor: 2) ==
                CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 2, rightDivisor: 4) ==
                CGRect(x: 0.75, y: 0, width: 0.25, height: 0.5))
    }

    @Test func cropsFromLeftAndBottomTogether() {
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 1, rightDivisor: 1, leftDivisor: 3) ==
                CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1))
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 2, rightDivisor: 1, leftDivisor: 4) ==
                CGRect(x: 0, y: 0, width: 0.25, height: 0.5))
    }

    @Test func cropsFromCenterAndBottomTogether() {
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 1, rightDivisor: 1, centerDivisor: 3) ==
                CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1))
        #expect(GameTimeMapper.regionOfInterest(bottomDivisor: 2, rightDivisor: 1, centerDivisor: 4) ==
                CGRect(x: 0.375, y: 0, width: 0.25, height: 0.5))
    }

    @Test func rejectsLeftAndRightDivisorsTogether() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/divisor-hstack-reversed.mp4")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        await #expect(throws: Error.self) {
            try await GameTimeMapper.map(videoURL: video, outputURL: output,
                                         rightDivisor: 3, leftDivisor: 3)
        }
    }

    @Test func mergesFrozenClockAcrossMissingReadings() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "3RD", gameSecond: 252), at: 0, until: 0.5, to: &entries)
        GameTimeMapper.add(.init(period: "3RD", gameSecond: 252), at: 20, until: 20.5, to: &entries)
        GameTimeMapper.add(.init(period: "3RD", gameSecond: 252), at: 202.5, until: 203, to: &entries)
        #expect(entries.count == 1)
        #expect(entries[0].video_start_seconds == 0)
        #expect(entries[0].video_end_seconds == 203)
        #expect(entries[0].game_start_seconds == 252)
        #expect(entries[0].game_end_seconds == 252)
    }

    @Test func recordsStoppedClockAndExplicitJSONFields() throws {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 117), at: 13, until: 13.5, to: &entries)
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 117), at: 13.5, until: 14, to: &entries)
        #expect(entries[0].game_start_seconds == 117)
        #expect(entries[0].game_end_seconds == 117)
        let json = String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)
        #expect(json.contains("game_start_seconds"))
        #expect(json.contains("game_end_seconds"))
        #expect(json.contains("video_start_seconds"))
        #expect(json.contains("video_end_seconds"))
        #expect(!json.contains("\"game_second\""))
    }

    @Test func mergesOnlyContinuousClockAndVideoTime() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 100), at: 0, until: 1, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 99), at: 1, until: 2, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 98), at: 3, until: 4, to: &entries)
        GameTimeMapper.add(.init(period: "1ST", gameSecond: 96), at: 4, until: 5, to: &entries)
        #expect(entries.map(\.game_start_seconds) == [100, 98, 96])
        #expect(entries[0].video_end_seconds == 2)
    }

    @Test func mergesShortGapsWhenClockRemainsContinuous() {
        var entries: [GameTimeMapper.Entry] = []
        for (clock, start, end) in [(116.0, 69.0, 81.0), (103, 82, 85),
                                    (100, 85.5, 100.5), (84, 101, 126)] {
            GameTimeMapper.add(.init(period: "2ND", gameSecond: clock),
                               at: start, until: end, to: &entries)
        }
        #expect(entries == [.init(period: "2ND", game_start_seconds: 116, game_end_seconds: 84,
                                  video_start_seconds: 69, video_end_seconds: 126)])
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 82), at: 128, until: 129, to: &entries)
        #expect(entries.count == 2)
    }

    @Test func mergesWholeSecondToFractionalClockTransition() {
        var entries: [GameTimeMapper.Entry] = []
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 116), at: 69, until: 126, to: &entries)
        GameTimeMapper.add(.init(period: "2ND", gameSecond: 59.8), at: 126, until: 145, to: &entries)
        #expect(entries == [.init(period: "2ND", game_start_seconds: 116, game_end_seconds: 59.8,
                                  video_start_seconds: 69, video_end_seconds: 145)])
    }

    @Test func postprocessesOnlyMatchingGaps() {
        let entries: [GameTimeMapper.Entry] = [
            .init(period: "2ND", game_start_seconds: 216, game_end_seconds: 214,
                  video_start_seconds: 0, video_end_seconds: 1.5),
            .init(period: "2ND", game_start_seconds: 212, game_end_seconds: 211,
                  video_start_seconds: 4, video_end_seconds: 5),
            .init(period: "2ND", game_start_seconds: 210, game_end_seconds: 209,
                  video_start_seconds: 5, video_end_seconds: 6.039366666666667),
            .init(period: "2ND", game_start_seconds: 180, game_end_seconds: 179,
                  video_start_seconds: 7, video_end_seconds: 8)
        ]
        let merged = GameTimeMapper.mergeContinuousIntervals(entries)
        #expect(merged.count == 2)
        #expect(merged[0] == .init(period: "2ND", game_start_seconds: 216,
                                  game_end_seconds: 209, video_start_seconds: 0,
                                  video_end_seconds: 6.039366666666667))
        #expect(merged[1] == entries[3])
    }

    @Test func postprocessKeepsPausedBoundaries() {
        let entries: [GameTimeMapper.Entry] = [
            .init(period: "2ND", game_start_seconds: 216, game_end_seconds: 214,
                  video_start_seconds: 0, video_end_seconds: 2),
            .init(period: "2ND", game_start_seconds: 214, game_end_seconds: 214,
                  video_start_seconds: 2, video_end_seconds: 3),
            .init(period: "2ND", game_start_seconds: 214, game_end_seconds: 214,
                  video_start_seconds: 4, video_end_seconds: 5),
            .init(period: "2ND", game_start_seconds: 213, game_end_seconds: 212,
                  video_start_seconds: 5, video_end_seconds: 6),
            .init(period: "2ND", game_start_seconds: 212, game_end_seconds: 212,
                  video_start_seconds: 6, video_end_seconds: 7),
            .init(period: "2ND", game_start_seconds: 211, game_end_seconds: 211,
                  video_start_seconds: 7, video_end_seconds: 8)
        ]
        let merged = GameTimeMapper.mergeContinuousIntervals(entries)
        #expect(merged.count == 5)
        #expect(merged[0] == entries[0])
        #expect(merged[1] == .init(period: "2ND", game_start_seconds: 214,
                                  game_end_seconds: 214, video_start_seconds: 2,
                                  video_end_seconds: 5))
        #expect(merged[2] == entries[3])
        #expect(merged[3] == entries[4])
        #expect(merged[4] == entries[5])
    }

    @Test func mergesInterruptedContinuousVideoWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/interrupted-continuous.mp4")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries == [.init(period: "2ND", game_start_seconds: 216,
                                  game_end_seconds: 209, video_start_seconds: 0,
                                  video_end_seconds: 6.039366666666667)])
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }
    @Test func parsesPeriodAndClock() {
        #expect(GameTimeMapper.parse(["1ST", "07:20"]) == .init(period: "1ST", gameSecond: 440))
        #expect(GameTimeMapper.parse(["2ND 00:59.9"]) == .init(period: "2ND", gameSecond: 59.9))
        #expect(GameTimeMapper.parse(["3RD", ":06.1"]) == .init(period: "3RD", gameSecond: 6.1))
        for (ocr, period) in [("1 ST", "1ST"), ("2 ND", "2ND"),
                              ("3 RD", "3RD"), ("4 TH", "4TH")] {
            #expect(GameTimeMapper.parse([ocr, "07:20"]) ==
                    .init(period: period, gameSecond: 440))
        }
        #expect(GameTimeMapper.parse(["3RD", "06.1"]) == .init(period: "3RD", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["3RD", "6.1"]) == .init(period: "3RD", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["4TH 59.9"]) == .init(period: "4TH", gameSecond: 59.9))
        #expect(GameTimeMapper.parse(["4TH", "07", ":", "20"]) == .init(period: "4TH", gameSecond: 440))
        #expect(GameTimeMapper.parse(["OT", "00:00"]) == .init(period: "OT", gameSecond: 0))
        #expect(GameTimeMapper.parse(["nGS", "SAC : 34 2ND 1:57 24 67 SAS", "SAC", "34", "67", "SAS"]) == .init(period: "2ND", gameSecond: 117))
        #expect(GameTimeMapper.parse(["SAC : 34 1:57 2ND 24 67 SAS"]) == .init(period: "2ND", gameSecond: 117))
        #expect(GameTimeMapper.parse(["SAC : 34 2ND 24"]) == nil)
        #expect(GameTimeMapper.parse(["5TH", "07:20"]) == nil)
        #expect(GameTimeMapper.parse(["OT", "07:60"]) == nil)
        #expect(GameTimeMapper.parse(["OT", "60.0"]) == nil)
    }

    @Test func selectedScoreboardFormatsControlParsing() {
        let digital = GameTimeMapper.ScoreboardFormat.Preset.a.format
        let long = GameTimeMapper.ScoreboardFormat.Preset.b.format
        let natural = GameTimeMapper.ScoreboardFormat.Preset.c.format
        #expect(GameTimeMapper.parse(["1ST", "11:01"], format: digital) ==
                .init(period: "1ST", gameSecond: 661))
        #expect(GameTimeMapper.parse(["2ND", ":06.1"], format: digital) ==
                .init(period: "2ND", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["2ND", "6.1"], format: digital) == nil)
        #expect(GameTimeMapper.parse(["FIRST QUARTER", "8:11"], format: long) ==
                .init(period: "1ST", gameSecond: 491))
        #expect(GameTimeMapper.parse(["SECOND QUARTER", "16.1"], format: long) ==
                .init(period: "2ND", gameSecond: 16.1))
        #expect(GameTimeMapper.parse(["THIRD QUARTER", "6.1"], format: long) ==
                .init(period: "3RD", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["FOURTH QUARTER", ":06.1"], format: long) == nil)
        #expect(GameTimeMapper.parse(["OVERTIME", "6.1"], format: long) ==
                .init(period: "OT", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["1ST", "06.1"], format: natural) == nil)
        #expect(GameTimeMapper.parse(["4TH", "59.9"], format: natural) ==
                .init(period: "4TH", gameSecond: 59.9))
        var custom = digital
        custom.periodStyles[.second] = .long
        #expect(GameTimeMapper.parse(["SECOND QUARTER", ":09.8"], format: custom) ==
                .init(period: "2ND", gameSecond: 9.8))
        #expect(GameTimeMapper.parse(["2ND", ":09.8"], format: custom) == nil)
    }

    @Test func parsesCyrillicLookalikesInShortPeriodLabels() {
        let short = GameTimeMapper.ScoreboardFormat.Preset.a.format
        let long = GameTimeMapper.ScoreboardFormat.Preset.b.format
        for (ocr, period) in [("4тH", "4TH"), ("4тн", "4TH"),
                              ("оT", "OT"), ("от", "OT")] {
            let expected = GameTimeMapper.Reading(period: period, gameSecond: 76)
            #expect(GameTimeMapper.parse([ocr, "1:16"]) == expected)
            #expect(GameTimeMapper.parse([ocr, "1:16"], format: short) == expected)
            #expect(GameTimeMapper.parse([ocr, "1:16"], format: long) == nil)
        }
    }

    @Test func prioritizesClockFormatsAndLargerUnderMinuteReading() {
        let digital = GameTimeMapper.ScoreboardFormat.Preset.a.format
        let natural = GameTimeMapper.ScoreboardFormat.Preset.c.format
        #expect(GameTimeMapper.parse(["1ST", ":59.9", "1:02"], format: digital) ==
                .init(period: "1ST", gameSecond: 62))
        #expect(GameTimeMapper.parse(["1ST :59.9 1:02"], format: digital) ==
                .init(period: "1ST", gameSecond: 62))
        #expect(GameTimeMapper.parse(["1ST", ":08.3", ":42.1"], format: digital) ==
                .init(period: "1ST", gameSecond: 42.1))
        #expect(GameTimeMapper.parse(["1ST :08.3 :42.1"], format: digital) ==
                .init(period: "1ST", gameSecond: 42.1))
        #expect(GameTimeMapper.parse(["1ST", "59.9", "1:02"], format: natural) ==
                .init(period: "1ST", gameSecond: 62))
        #expect(GameTimeMapper.parse(["1ST 8.3 42.1"], format: natural) ==
                .init(period: "1ST", gameSecond: 42.1))
        #expect(GameTimeMapper.parse(["1ST", "1:60", ":42.1"], format: digital) ==
                .init(period: "1ST", gameSecond: 42.1))
    }

    @Test func parsesCyrillicSixInMinuteClock() {
        let format = GameTimeMapper.ScoreboardFormat.Preset.a.format
        for (clock, seconds) in [("7:1б", 436.0), ("6:4Б", 406.0), ("2:0Б", 126.0)] {
            #expect(GameTimeMapper.parse(["4TH", clock], format: format) ==
                    .init(period: "4TH", gameSecond: seconds))
        }
        #expect(GameTimeMapper.parse(["4TH", "7:1Г"], format: format) == nil)
    }

    @Test(arguments: ["minutes-seconds.mp4", "seconds-fractional.mp4"])
    func mapsBundledVideo(_ name: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/\(name)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }
        var samples: [GameTimeMapper.Sample] = []
        var logs: [String] = []
        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output, recognize: { _ in
            ["1ST", name == "minutes-seconds.mp4" ? "07:20" : ":06.1"]
        }, log: { logs.append($0) }, onSample: { samples.append($0) })
        #expect(!entries.isEmpty)
        #expect(!samples.isEmpty)
        #expect(samples.map(\.logLine) == logs)
        #expect(samples.allSatisfy { $0.ocrTexts.count == 2 })
        #expect(samples.allSatisfy { $0.reading?.period == "1ST" })
        #expect(samples.map(\.videoSecond) == samples.map(\.videoSecond).sorted())
        #expect(entries.allSatisfy { $0.period == "1ST" && $0.video_start_seconds < $0.video_end_seconds })
        #expect(entries.first?.game_start_seconds == (name == "minutes-seconds.mp4" ? 440 : 6.1))
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }

    @Test func mapsUncroppedBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-only.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries.map(\.game_start_seconds) == [442])
        #expect(entries.allSatisfy { $0.period == "2ND" })
        #expect(entries.first?.video_start_seconds == 0)
        #expect(entries.last?.video_end_seconds == 3)
    }

    @Test func mapsBottomHalfOfBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-only.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output, bottomDivisor: 2)
        #expect(entries.map(\.game_start_seconds) == [442])
        #expect(entries.allSatisfy { $0.period == "2ND" })
        #expect(entries.first?.video_start_seconds == 0)
        #expect(entries.last?.video_end_seconds == 3)
    }

    @Test func mapsSelectedRegionThenSavesJSON() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-only.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video,
                                                   regionOfInterest: CGRect(x: 0, y: 0, width: 1, height: 0.5))
        #expect(entries.map(\.game_start_seconds) == [442])
        #expect(!FileManager.default.fileExists(atPath: output.path))
        try GameTimeMapper.save(entries, to: output)
        let saved = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(saved == entries)
    }

    @Test func mapsBottomThirdOfVerticalStackWithVision() async throws {
        try await expectFrozenScoreboard(in: "divisor-vstack.mp4", bottomDivisor: 3, rightDivisor: 1)
    }

    @Test func mapsRightThirdOfHorizontalStackWithVision() async throws {
        try await expectFrozenScoreboard(in: "divisor-hstack.mp4", bottomDivisor: 1, rightDivisor: 3)
    }

    @Test func mapsLeftThirdOfHorizontalStackWithVision() async throws {
        try await expectFrozenScoreboard(in: "divisor-hstack-reversed.mp4", bottomDivisor: 1,
                                         rightDivisor: 1, leftDivisor: 3)
    }

    @Test func mapsCenterThirdOfHorizontalStackWithVision() async throws {
        try await expectFrozenScoreboard(in: "divisor-hstack-center.mp4", bottomDivisor: 1,
                                         rightDivisor: 1, centerDivisor: 3)
    }

    @Test func mapsBottomRightTileOfSquareStackWithVision() async throws {
        try await expectFrozenScoreboard(in: "divisor-square.mp4", bottomDivisor: 3, rightDivisor: 3)
    }

    private func expectFrozenScoreboard(in name: String, bottomDivisor: Int,
                                        rightDivisor: Int, leftDivisor: Int = 1,
                                        centerDivisor: Int = 1) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/\(name)")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output,
                                                   bottomDivisor: bottomDivisor,
                                                   rightDivisor: rightDivisor,
                                                   leftDivisor: leftDivisor,
                                                   centerDivisor: centerDivisor)
        #expect(entries.count == 1)
        #expect(entries.first?.game_start_seconds == 357)
        #expect(entries.first?.game_end_seconds == 357)
        #expect(entries.first?.video_start_seconds == 0)
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        #expect(duration > 2.9 && duration < 3.1)
        #expect(entries.first?.video_end_seconds == duration)
    }

    @Test func mapsFractionalBroadcastWithVision() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let video = root.appendingPathComponent("test-data/trimmed-including-fractional.mov")
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: output) }

        let entries = try await GameTimeMapper.map(videoURL: video, outputURL: output)
        #expect(entries.map(\.game_start_seconds) == [62])
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
        #expect(entries.first?.video_start_seconds == 2.5)
        #expect(entries.map(\.game_start_seconds) == [718])
        #expect(entries.allSatisfy { $0.period == "3RD" })
        let decoded = try JSONDecoder().decode([GameTimeMapper.Entry].self, from: Data(contentsOf: output))
        #expect(decoded == entries)
    }
}
