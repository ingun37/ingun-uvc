import Foundation
import Testing

struct GametimeMapperTests {
    @Test func parsesPeriodAndClock() {
        #expect(GameTimeMapper.parse(["1ST", "07:20"]) == .init(period: "1ST", gameSecond: 440))
        #expect(GameTimeMapper.parse(["2ND 00:59.9"]) == .init(period: "2ND", gameSecond: 59.9))
        #expect(GameTimeMapper.parse(["3RD", ":06.1"]) == .init(period: "3RD", gameSecond: 6.1))
        #expect(GameTimeMapper.parse(["4TH", "07", ":", "20"]) == .init(period: "4TH", gameSecond: 440))
        #expect(GameTimeMapper.parse(["OT", "00:00"]) == .init(period: "OT", gameSecond: 0))
        #expect(GameTimeMapper.parse(["5TH", "07:20"]) == nil)
        #expect(GameTimeMapper.parse(["OT", "07:60"]) == nil)
    }

    @Test(arguments: ["minutes-seconds.mp4", "seconds-fractional.mp4"])
    func mapsBundledVideo(_ name: String) async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let video = root.appendingPathComponent("time_mapper_lib/test-data/\(name)")
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
}
