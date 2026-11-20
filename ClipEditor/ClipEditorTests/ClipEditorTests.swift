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

    @Test func basketSideIgnoresMiddleColumns() throws {
        let detector = try BasketSide()
        guard let context = CGContext(data: nil, width: 64, height: 4, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BasketSide.DetectionError.computeFailed
        }
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 4))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 4))
        context.fill(CGRect(x: 48, y: 0, width: 16, height: 4))
        context.fill(CGRect(x: 16, y: 0, width: 16, height: 4))
        guard let image = context.makeImage() else { throw BasketSide.DetectionError.computeFailed }
        #expect(try !detector.isRight(image))
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

    @Test func boxScoreExcludesNonPlayingPlayersAndMatchesExportName() throws {
        let csv = "game_id,team,player_id,player,position,minutes,comment,points,reboundsTotal\n" +
            "1,BOS,11,José Player,G,31:20,,24,7\n" +
            "1,BOS,12,Bench Player,, ,DNP - Coach's Decision,0,0\n"
        let score = try BoxScore(csv: csv)
        #expect(score.players.count == 1)
        #expect(score.players[0].matches("BOS|Jose Player"))
        #expect(score.players[0].value("points") == "24")
    }

    @Test @MainActor func rendersBothBoxScoreViewsAtTemplateSize() throws {
        let score = try BoxScore(csv: """
        game_id,team,player_id,player,position,minutes,comment,points,reboundsTotal
        1,BOS,11,Sample Player,G,31:20,,24,7
        1,LAL,12,Other Player,F,29:14,,18,9
        """)
        let compilation = try BoxScoreVideo.render(CompilationBoxScoreView(boxScore: score, date: nil))
        let player = try BoxScoreVideo.render(PlayerBoxScoreView(player: score.players[0]))
        #expect(compilation.width == 1920 && compilation.height == 1080)
        #expect(player.width == 1080 && player.height == 1080)
    }

    @Test func appendsStillBoxScoreToVideo() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sample.mp4")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-boxscore-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        guard let context = CGContext(data: nil, width: 16, height: 9, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw BoxScoreVideo.RenderError.image
        }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        let image = try #require(context.makeImage())
        try await VideoCompilation.export(videoURL: fixture,
            clips: [Clip(start: 0.5, end: 2, descriptions: ["miss"])],
            destination: output, endCard: image)
        let asset = AVURLAsset(url: output)
        #expect(abs(try await asset.load(.duration).seconds - 6.5) < 0.1)
        let generator = AVAssetImageGenerator(asset: asset)
        let finalFrame = try generator.copyCGImage(at: CMTime(seconds: 5, preferredTimescale: 600),
                                                   actualTime: nil)
        #expect(finalFrame.width == 320)
        let pixels = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
        defer { pixels.deallocate() }
        let sample = try #require(CGContext(data: pixels, width: 1, height: 1,
            bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(finalFrame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(Int(pixels[0]) > Int(pixels[1]) + 100)
    }

    @Test func countHistoryIncludesMadeShotsBetweenMisses() throws {
        let csv = "period,clock,team,player,player_full_name,result,description\n" +
            "1,PT11M00S,A,One,Alice,missed,miss\n" +
            "1,PT10M00S,A,One,Alice,made,make\n" +
            "1,PT09M00S,A,One,Alice,missed,miss\n"
        let events = try #require(ClipPlanner.countEvents(from: csv)["A|Alice"])
        #expect(events.map(\.attempted) == [1, 2, 3])
        #expect(events.map(\.made) == [0, 1, 1])
        #expect(events.map(\.isMade) == [false, true, false])
        #expect(events[1].gameTime == "1st 10′0″")
    }

    @Test func exportedPlayerRankingsUseGameTotalsAndOnlyExportedPlayers() throws {
        let csv = "period,clock,team,player,result,description\n" +
            "1,PT11M00S,A,Alice,missed,miss\n" +
            "1,PT10M00S,A,Alice,made,make\n" +
            "1,PT09M00S,A,Alice,missed,miss\n" +
            "1,PT08M00S,B,Bob,missed,miss\n" +
            "1,PT07M00S,B,Bob,missed,miss\n" +
            "1,PT06M00S,C,Chris,made,make\n"
        let events = try ClipPlanner.countEvents(from: csv)
        let stats = PlayerFieldGoalStats.exportedPlayers(["A|Alice", "B|Bob"], countEvents: events)
        #expect(PlayerFieldGoalStats.byMisses(stats).map(\.id) == ["A|Alice", "B|Bob"])
        #expect(PlayerFieldGoalStats.byPercentage(stats).map(\.id) == ["B|Bob", "A|Alice"])
        #expect(stats.first?.misses == 2)
        #expect(abs((stats.first?.percentage ?? 0) - 100.0 / 3.0) < 0.001)
        #expect(stats.count == 2)
    }

    @Test func madeShotTimeUsesPeriodAndPrimeNotation() throws {
        let csv = "period,clock,team,player,result,description\n" +
            "2,PT11M02S,A,Alice,made,make\n"
        let event = try #require(ClipPlanner.countEvents(from: csv)["A|Alice"]?.first)
        #expect(event.gameTime == "2nd 11′2″")
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

    @Test func timingHandlesKeepCaptionsAndWindowInSync() {
        let attempts = [
            ClipAttempt(sourceTime: 12, text: "Alice\n0/1", location: nil, player: "A|Alice"),
            ClipAttempt(sourceTime: 15, text: "Bob\n0/1", location: nil, player: "B|Bob")
        ]
        var clip = Clip(start: 8, end: 18, descriptions: ["two misses"], attempts: attempts)
        let range = 0.0...30.0

        clip.moveHandle(1, to: 13, moveAll: false, in: range)
        #expect(clip.start == 8 && clip.end == 18)
        #expect(clip.captions.map(\.sourceTime) == [13, 15])

        clip.moveHandle(2, to: 17, moveAll: true, in: range)
        #expect(clip.start == 10 && clip.end == 20)
        #expect(clip.captions.map(\.sourceTime) == [15, 17])

        clip.moveHandle(0, to: -100, moveAll: true, in: range)
        #expect(clip.start == 0 && clip.end == 10)
        #expect(clip.captions.map(\.sourceTime) == [5, 7])

        clip.resetTiming()
        #expect(clip.timingIsOriginal)
        #expect(clip.captions.map(\.sourceTime) == [12, 15])
    }

    @Test func uncaptionedAttemptStillHasHandleAndHandlesStayOrdered() throws {
        let attempts = [MissedAttempt(period: "1ST", gameSecond: 100, description: "miss")]
        let ranges = [ClockRange(period: "1ST", game_start_seconds: 100, game_end_seconds: 90,
                                 video_start_seconds: 10, video_end_seconds: 20)]
        var clip = try #require(ClipPlanner.plan(attempts: attempts, ranges: ranges,
                                                 videoDuration: 30).clips.first)
        #expect(clip.attempts.count == 1)
        #expect(clip.captions.isEmpty)
        clip.moveHandle(0, to: 25, moveAll: false, in: 0...30)
        #expect(clip.start == clip.attempts[0].sourceTime)
        clip.moveHandle(1, to: 25, moveAll: false, in: 0...30)
        #expect(clip.attempts[0].sourceTime == clip.end)
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

    @Test func exportsAnimatedCountFromShortFixture() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test-data/short-2")
        let csv = try String(contentsOf: root.appending(path: "first-quarter-only.csv"), encoding: .utf8)
        let ranges = try JSONDecoder().decode([ClockRange].self,
            from: Data(contentsOf: root.appending(path: "first-quarter-only.json")))
        let video = root.appending(path: "first-quarter-only.mov")
        let duration = try await AVURLAsset(url: video).load(.duration).seconds
        let plan = try ClipPlanner.plan(attempts: ClipPlanner.attempts(from: csv),
                                        ranges: ranges, videoDuration: duration)
        let player = "DET|Cade Cunningham"
        let clips = plan.clips.filter { $0.players.contains(player) }
        let events = try #require(ClipPlanner.countEvents(from: csv)[player])
        #expect(!clips.isEmpty)
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-animated-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        try await VideoCompilation.export(videoURL: video, clips: clips, destination: output,
                                          title: "Cade Cunningham", player: player, square: true,
                                          countEvents: events)
        #expect(FileManager.default.fileExists(atPath: output.path))
    }
}
