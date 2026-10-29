import AVFoundation
import Foundation
import Testing
@testable import ClipEditor

struct ClipEditorTests {
    @Test func readsMissedAttemptsIncludingQuotedCSV() throws {
        let csv = "game_id,period,clock,team,player,result,description\n" +
            "1,1,PT11M33.00S,A,One,missed,\"Miss, with comma\"\n" +
            "1,1,PT11M30.00S,A,Two,made,Made\n" +
            "1,5,PT02M01.50S,B,Three,missed,Overtime\n"
        let attempts = try ClipPlanner.attempts(from: csv)
        #expect(attempts.count == 2)
        #expect(attempts[0].period == "1ST")
        #expect(attempts[0].gameSecond == 693)
        #expect(attempts[0].description == "Miss, with comma")
        #expect(attempts[1].period == "OT")
        #expect(attempts[1].gameSecond == 121.5)
    }

    @Test func readsDataFetcherCRLFFile() throws {
        let csv = "game_id,period,clock,team,player,result,description\r\n" +
            "0012600061,1,PT11M33.00S,SAS,Vassell,missed,MISS Vassell 27' 3PT Jump Shot\r\n"
        let attempts = try ClipPlanner.attempts(from: csv)
        #expect(!attempts.isEmpty)
    }

    @Test func mapsClampsAndMergesOverlappingMisses() throws {
        let attempts = [
            MissedAttempt(period: "1ST", gameSecond: 693, description: "first"),
            MissedAttempt(period: "1ST", gameSecond: 690, description: "second"),
            MissedAttempt(period: "2ND", gameSecond: 693, description: "unmatched")
        ]
        let ranges = [
            ClockRange(period: "1ST", game_second: 693, start_seconds: 4, end_seconds: 4.5),
            ClockRange(period: "1ST", game_second: 690, start_seconds: 9, end_seconds: 9.5)
        ]
        let plan = try ClipPlanner.plan(attempts: attempts, ranges: ranges, videoDuration: 10)
        #expect(plan.clips.count == 1)
        #expect(plan.clips[0].start == 0)
        #expect(plan.clips[0].end == 10)
        #expect(plan.clips[0].descriptions == ["first", "second"])
        #expect(plan.unmatched.count == 1)
    }
    @Test func exportsVideoAndAudioWithClipTransitions() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sample.mp4")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let clips = [
            Clip(start: 0.5, end: 2, descriptions: ["first"]),
            Clip(start: 2.5, end: 4, descriptions: ["second"])
        ]
        try await VideoCompilation.export(videoURL: fixture, clips: clips, destination: output)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 3) < 0.1)
        #expect(try await asset.loadTracks(withMediaType: .video).count == 1)
        #expect(try await !asset.loadTracks(withMediaType: .audio).isEmpty)
        try await VideoCompilation.export(videoURL: fixture, clips: clips, destination: output)
        let replacement = AVURLAsset(url: output)
        #expect(try await !replacement.loadTracks(withMediaType: .video).isEmpty)
    }
}
