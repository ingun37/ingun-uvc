import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import ClipEditor

struct ClipEditorTests {
    @Test func invalidMappingIdentifiesEntryAndValues() throws {
        let ranges = [ClockRange(period: "1ST", game_start_seconds: 100, game_end_seconds: 90,
                                 video_start_seconds: 12, video_end_seconds: 10)]
        do {
            _ = try ClipPlanner.plan(attempts: [], ranges: ranges, videoDuration: 20)
            Issue.record("Expected an invalid mapping error")
        } catch let error as ClipPlanningError {
            #expect(error.localizedDescription.contains("entry 1 (period 1ST)"))
            #expect(error.localizedDescription.contains("start 12.0, end 10.0"))
        }
    }

    @Test func darkerHalfDeterminesBasketSide() throws {
        let detector = try BasketSide()
        func image(left: CGFloat, right: CGFloat) throws -> CGImage {
            guard let context = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw BasketSide.DetectionError.computeFailed
            }
            context.setFillColor(CGColor(gray: left, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            context.setFillColor(CGColor(gray: right, alpha: 1))
            context.fill(CGRect(x: 4, y: 0, width: 4, height: 4))
            guard let result = context.makeImage() else { throw BasketSide.DetectionError.computeFailed }
            return result
        }
        #expect(try detector.isRight(image(left: 1, right: 0)))
        #expect(try !detector.isRight(image(left: 0, right: 1)))
        #expect(try !detector.isRight(image(left: 0.5, right: 0.5)))
    }

    @Test func interpolatesWithinContinuousClockRangeAndLeavesGapsUnmatched() throws {
        let attempts = [
            MissedAttempt(period: "1ST", gameSecond: 97, description: "middle"),
            MissedAttempt(period: "1ST", gameSecond: 90, description: "gap")
        ]
        let ranges = [ClockRange(period: "1ST", game_start_seconds: 100, game_end_seconds: 95, video_start_seconds: 20, video_end_seconds: 25)]
        let plan = try ClipPlanner.plan(attempts: attempts, ranges: ranges, videoDuration: 40)
        #expect(plan.clips.count == 1)
        #expect(plan.clips[0].start == 19)
        #expect(plan.clips[0].end == 25)
        #expect(plan.clips[0].gameTimes == ["1ST 01:37.00"])
        #expect(plan.unmatched.count == 1)
    }
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
            ClockRange(period: "1ST", game_start_seconds: 693, game_end_seconds: 692.5, video_start_seconds: 4, video_end_seconds: 4.5),
            ClockRange(period: "1ST", game_start_seconds: 690, game_end_seconds: 689.5, video_start_seconds: 9, video_end_seconds: 9.5)
        ]
        let plan = try ClipPlanner.plan(attempts: attempts, ranges: ranges, videoDuration: 10)
        #expect(plan.clips.count == 1)
        #expect(plan.clips[0].start == 0)
        #expect(plan.clips[0].end == 10)
        #expect(plan.clips[0].descriptions == ["first", "second"])
        #expect(plan.clips[0].gameTimes == ["1ST 11:33.00", "1ST 11:30.00"])
        #expect(plan.unmatched.count == 1)
    }
    @Test func mergedClipRetainsEveryPlayer() throws {
        let attempts = [
            MissedAttempt(period: "1ST", gameSecond: 100, description: "A miss", player: "A|Alice"),
            MissedAttempt(period: "1ST", gameSecond: 97, description: "B miss", player: "B|Bob")
        ]
        let ranges = [ClockRange(period: "1ST", game_start_seconds: 100, game_end_seconds: 90,
                                 video_start_seconds: 10, video_end_seconds: 20)]
        let plan = try ClipPlanner.plan(attempts: attempts, ranges: ranges, videoDuration: 30)
        #expect(plan.clips.count == 1)
        #expect(Set(plan.clips[0].players) == Set(["A|Alice", "B|Bob"]))
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

    @Test func exportsSquarePlayerVideo() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sample.mp4")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-square-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await VideoCompilation.export(videoURL: fixture,
            clips: [Clip(start: 0.5, end: 2, descriptions: ["miss"])],
            destination: output, title: "Player", player: "A|Player", square: true)
        let track = try #require(await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(size.width - size.height) < 1)
    }
}
