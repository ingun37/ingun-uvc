import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import ClipEditor

struct ClipEditorTests {
    @Test func bundledCourtSpotMapFindsNearestLabel() throws {
        let map = try CourtSpotMap.bundled()
        #expect(map.nearestLabel(to: CGPoint(x: 0, y: 140)) == "Free Throw Line")
        #expect(map.nearestLabel(to: CGPoint(x: -230, y: 0)) == "Left Corner")
        #expect(map.nearestLabel(to: CGPoint(x: 78, y: 140)) == "Right Elbow")
    }

    @Test func areaEllipseSitsAtBoundingBoxBottomAndStaysInFrame() {
        let settings = ShotEffectSettings(ellipseWidthMultiplier: 2.4, duration: 2)
        let area = ShotEffectArea.ellipse(
            atBottomOf: CGRect(x: 50, y: 40, width: 60, height: 100),
            in: CGSize(width: 320, height: 180), settings: settings)
        #expect(abs(area.minX - 8) < 0.001)
        #expect(abs(area.minY - 119.84) < 0.001)
        #expect(abs(area.width - 144) < 0.001)
        #expect(abs(area.height - 40.32) < 0.001)
        let tallerBox = ShotEffectArea.ellipse(
            atBottomOf: CGRect(x: 50, y: 0, width: 60, height: 140),
            in: CGSize(width: 320, height: 180), settings: settings)
        #expect(abs(tallerBox.height - area.height) < 0.001)
        let widerBox = ShotEffectArea.ellipse(
            atBottomOf: CGRect(x: 50, y: 40, width: 120, height: 100),
            in: CGSize(width: 320, height: 180), settings: settings)
        #expect(widerBox.width > area.width && widerBox.height > area.height)
        let edge = ShotEffectArea.ellipse(
            atBottomOf: CGRect(x: 0, y: 160, width: 60, height: 100),
            in: CGSize(width: 320, height: 180), settings: settings)
        #expect(edge.minX >= 0 && edge.maxY <= 180)
    }

    @Test func shotEffectSettingsControlEllipseSize() throws {
        let settings = try #require(ShotEffectSettings.parse(ellipseSize: "1.5", duration: "3.5"))
        #expect(settings.duration == 3.5)
        let area = ShotEffectArea.ellipse(
            atBottomOf: CGRect(x: 50, y: 40, width: 60, height: 100),
            in: CGSize(width: 320, height: 180), settings: settings)
        #expect(abs(area.width - 90) < 0.001)
        #expect(abs(area.height - 25.2) < 0.001)
        #expect(ShotEffectSettings.parse(ellipseSize: "0", duration: "3") == nil)
        #expect(ShotEffectSettings.parse(ellipseSize: "2", duration: "NaN") == nil)
    }

    @Test func squareCropRequiresEntireBoundingBoxInside() {
        let frame = CGSize(width: 320, height: 180)
        #expect(ShotEffectArea.centeredSquareCrop(in: frame) == CGRect(x: 70, y: 0, width: 180, height: 180))
        #expect(ShotEffectArea.fitsInsideCenteredSquare(
            CGRect(x: 80, y: 20, width: 60, height: 100), in: frame))
        #expect(!ShotEffectArea.fitsInsideCenteredSquare(
            CGRect(x: 60, y: 20, width: 60, height: 100), in: frame))
        #expect(!ShotEffectArea.fitsInsideCenteredSquare(
            CGRect(x: 70, y: 20, width: 60, height: 100), in: frame))
        #expect(!ShotEffectArea.fitsInsideCenteredSquare(
            CGRect(x: 250, y: 20, width: 30, height: 100), in: frame))
    }

    @Test func boundingBoxResizeKeepsBoxInsideFrame() {
        let original = CGRect(x: 50, y: 40, width: 60, height: 100)
        let frame = CGSize(width: 320, height: 180)
        let adjusted = ShotEffectArea.resized(original, to: CGSize(width: 120, height: 80), in: frame)
        #expect(adjusted == CGRect(x: 20, y: 50, width: 120, height: 80))
        let clamped = ShotEffectArea.resized(original, to: CGSize(width: 500, height: 300), in: frame)
        #expect(clamped == CGRect(x: 0, y: 0, width: 320, height: 180))
    }

    @Test func localShotStatsUseNearestCourtSpotAndExcludeMissingLocations() throws {
        let mapping = try CourtSpotMap.bundled()
        let freeThrowLine = try #require(mapping.nearestSpotIndex(to: CGPoint(x: 0, y: 140)))
        let csv = "loc_x,loc_y,result\n" +
            "0,140,made\n0,175,missed\n78,140,made\n,140,made\n-10,150,made\n0,200,missed\n"
        let stats = try LocalShotStats.atSpot(freeThrowLine, in: csv, mapping: mapping)
        #expect(stats == LocalShotStats(makes: 2, attempts: 3))
        #expect(stats.percent == 67)
        #expect(!LocalShotStats(makes: 4, attempts: 9).hasEnoughSamplesForEffect)
        #expect(LocalShotStats(makes: 4, attempts: 10).hasEnoughSamplesForEffect)
    }

    @Test func acceptsDisplayedGameDate() {
        #expect(PlayerAttemptFetcher.gameDate("Nov 22, 2026") != nil)
        #expect(PlayerAttemptFetcher.gameDate("2026-11-22") != nil)
        #expect(PlayerAttemptFetcher.inputGameDate("Nov 16, 2026") == "Nov 16, 2026")
        #expect(PlayerAttemptFetcher.inputGameDate("Nov 31, 2026") == nil)
        #expect(PlayerAttemptFetcher.inputGameDate("2026-11-16") == nil)
    }

    @Test func savesFetchedPlayerAttemptsBesideInputVideo() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-player-shots-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appending(path: "game.mov")
        let saved = try PlayerAttemptFetcher.saveCopy("result\nmissed\n", shortName: "Vassell",
                                                       playerID: "1629027", beside: video)
        #expect(saved.lastPathComponent == "player-shots-Vassell-1629027.csv")
        #expect(saved.path == directory.appending(path: "player-shots-Vassell-1629027.csv").path)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "result\nmissed\n")
        _ = try PlayerAttemptFetcher.saveCopy("result\nmade\n", shortName: "Vassell",
                                              playerID: "1629027", beside: video)
        #expect(try String(contentsOf: saved, encoding: .utf8) == "result\nmade\n")
    }

    @Test func shotEffectHoldsAllPlayerVideo() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sample.mp4")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-effect-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let attempt = ClipAttempt(sourceTime: 1.3, text: nil, location: .zero,
                                  player: "A|Alice", playerID: "1", shotDescription: "Jump shot")
        let clip = Clip(start: 0.5, end: 2, descriptions: ["Jump shot"], attempts: [attempt])
        let width = 320, height = 180
        var mask = Data(count: width * height)
        for y in 40..<140 {
            for x in 50..<110 { mask[y * width + x] = 255 }
        }
        let effect = AppliedShotEffect(timestamp: 1, bounds: CGRect(x: 50, y: 40, width: 60, height: 100),
                                       frameSize: CGSize(width: width, height: height),
                                       maskPNG: Data(), maskPixels: mask, playerID: "1",
                                       playerName: "Alice", shotDescription: "Jump shot", shotLocation: .zero)
        let settings = ShotEffectSettings(ellipseWidthMultiplier: 1.5, duration: 3.5)
        try await VideoCompilation.export(videoURL: fixture, clips: [clip], destination: output,
            shotEffects: [ShotEffectKey(clipID: clip.id, attemptIndex: 0):
                PreparedShotEffect(effect: effect, stats: LocalShotStats(makes: 2, attempts: 3),
                                   spotLabel: "Low Post")], shotEffectSettings: settings)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - (1.5 + settings.duration)) < 0.15)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let early = try generator.copyCGImage(at: CMTime(seconds: 0.53, preferredTimescale: 600), actualTime: nil)
        let darkened = try generator.copyCGImage(at: CMTime(seconds: 0.9, preferredTimescale: 600), actualTime: nil)
        func brightness(_ image: CGImage, x: Int, y: Int) throws -> Int {
            let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
            defer { bytes.deallocate() }
            let context = try #require(CGContext(data: bytes, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
        }
        #expect(try brightness(darkened, x: 20, y: 20) < brightness(early, x: 20, y: 20))
        #expect(try abs(brightness(darkened, x: 80, y: 90) - brightness(early, x: 80, y: 90)) < 35)
        #expect(try brightness(darkened, x: 80, y: 140) > brightness(darkened, x: 20, y: 20))
    }

    @Test func shotEffectComposesFractionalCaptureTimes() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "test-data/short-2/first-quarter-only.mov")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-capture-effect-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let attempts = [
            ClipAttempt(sourceTime: 1.23, text: nil, location: .zero, player: "A|Alice"),
            ClipAttempt(sourceTime: 2.77, text: nil, location: .zero, player: "A|Alice")
        ]
        let clip = Clip(start: 0.1734567, end: 3.4195678, descriptions: ["two shots"], attempts: attempts)
        let width = 1920, height = 1080
        var mask = Data(count: width * height)
        for y in 300..<800 {
            for x in 200..<500 { mask[y * width + x] = 255 }
        }
        let releaseTimes = [0.9179876, 2.2491234]
        #expect(CMTime(seconds: releaseTimes[0], preferredTimescale: 60000) -
                CMTime(seconds: clip.start, preferredTimescale: 60000) !=
                CMTime(seconds: releaseTimes[0] - clip.start, preferredTimescale: 60000))
        let effects = Dictionary(uniqueKeysWithValues: releaseTimes.enumerated().map { index, time in
            let effect = AppliedShotEffect(timestamp: time,
                bounds: CGRect(x: 200, y: 300, width: 300, height: 500),
                frameSize: CGSize(width: width, height: height), maskPNG: Data(), maskPixels: mask,
                playerID: "1", playerName: "Alice", shotDescription: "Jump shot", shotLocation: .zero)
            return (ShotEffectKey(clipID: clip.id, attemptIndex: index),
                    PreparedShotEffect(effect: effect, stats: LocalShotStats(makes: 2, attempts: 3),
                                       spotLabel: "Low Post"))
        })
        try await VideoCompilation.export(videoURL: fixture, clips: [clip], destination: output,
                                          shotEffects: effects)
        let duration = try await AVURLAsset(url: output).load(.duration).seconds
        #expect(abs(duration - (clip.end - clip.start + 2 * ShotEffectSettings.defaults.duration)) < 0.15)
    }

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
        let csv = "game_id,period,clock,team,player,player_full_name,result,description\r\n" +
            "0012600061,1,PT11M33.00S,SAS,Vassell,Devin Vassell,missed,MISS Vassell 27' 3PT Jump Shot\r\n"
        let attempts = try ClipPlanner.attempts(from: csv)
        #expect(!attempts.isEmpty)
        #expect(attempts[0].shortName == "Vassell")
        #expect(attempts[0].player == "SAS|Devin Vassell")
        let plan = try ClipPlanner.plan(attempts: attempts,
            ranges: [ClockRange(period: "1ST", game_start_seconds: 700, game_end_seconds: 680,
                                video_start_seconds: 0, video_end_seconds: 20)], videoDuration: 25)
        #expect(plan.clips.first?.attempts.first?.shortName == "Vassell")
    }

    @Test func shotEffectCaptionUsesRequestedLinesAndPercentageColor() throws {
        let effect = AppliedShotEffect(timestamp: 1, bounds: .zero, frameSize: CGSize(width: 1, height: 1),
                                       maskPNG: Data(), maskPixels: Data(), playerID: "1",
                                       playerName: "Vassell", shotDescription: "3PT Jump Shot", shotLocation: nil)
        let font = NSFont.systemFont(ofSize: 24)
        let caption = ShotEffectRendering.caption(
            for: PreparedShotEffect(effect: effect, stats: LocalShotStats(makes: 3, attempts: 10),
                                    spotLabel: "Left Corner"), font: font)
        #expect(caption.string == "Vassell's\nrecent\n3PT Jump Shot\nat the\nLeft Corner\n30% (3/10)")
        let percentageRange = (caption.string as NSString).range(of: "30%")
        let percentageColor = try #require(caption.attribute(.foregroundColor, at: percentageRange.location,
                                                              effectiveRange: nil) as? NSColor)
        let middle = ColorTheme.shotPercentageColor(35)
        #expect(percentageColor.isEqual(ColorTheme.shotPercentageColor(30)))
        #expect(middle.redComponent < ColorTheme.shotPercentageColor(20).redComponent)
        #expect(middle.greenComponent > ColorTheme.shotPercentageColor(20).greenComponent)
        #expect(middle.redComponent > ColorTheme.shotPercentageColor(50).redComponent)
        #expect(middle.greenComponent < ColorTheme.shotPercentageColor(50).greenComponent)
        #expect(ColorTheme.shotPercentageColor(0).isEqual(ColorTheme.shotPercentageColor(20)))
        #expect(ColorTheme.shotPercentageColor(100).isEqual(ColorTheme.shotPercentageColor(50)))
        let countIndex = (caption.string as NSString).range(of: "3/10").location
        let countColor = try #require(caption.attribute(.foregroundColor, at: countIndex,
                                                         effectiveRange: nil) as? NSColor)
        #expect(countColor.isEqual(ColorTheme.fontColor1NS))
    }

    @Test func stripsMatchingMissAndShortNameFromShotDescriptions() throws {
        let csv = "period,clock,team,player,result,description\n" +
            "1,PT11M44S,SAS,Vassell,missed,MISS Vassell 27' 3PT Jump Shot\n" +
            "1,PT11M20S,NOP,Matković,missed,MISS Matkovic 3' Cutting Dunk Shot\n" +
            "1,PT11M00S,SAS,Vassell,missed,MISS Vassellton Jump Shot\n" +
            "1,PT10M40S,SAS,Vassell,missed,MISS Vassell 3PT Jump Shot\n"
        let attempts = try ClipPlanner.attempts(from: csv)
        #expect(attempts.map(\.description) == [
            "3PT Jump Shot", "Cutting Dunk Shot", "MISS Vassellton Jump Shot", "3PT Jump Shot"
        ])
        let plan = try ClipPlanner.plan(attempts: attempts,
            ranges: [ClockRange(period: "1ST", game_start_seconds: 704, game_end_seconds: 660,
                                video_start_seconds: 0, video_end_seconds: 44)],
            videoDuration: 50)
        #expect(plan.clips.first?.attempts.first?.shotDescription == "3PT Jump Shot")
    }

    @Test func boxScoreExcludesNonPlayingPlayersAndMatchesExportName() throws {
        let csv = "game_id,team,player_id,player,position,minutes,comment,points,reboundsTotal,fieldGoalsMade,fieldGoalsAttempted\n" +
            "1,BOS,11,José Player,G,31:20,,24,7,9,18\n" +
            "1,BOS,12,Bench Player,, ,DNP - Coach's Decision,0,0,0,0\n"
        let score = try BoxScore(csv: csv)
        #expect(score.players.count == 1)
        #expect(score.players[0].matches("BOS|Jose Player"))
        #expect(score.players[0].value("points") == "24")
        #expect(score.players[0].value("fieldGoalsMade/fieldGoalsAttempted") == "9/18")
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
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let transitionFrame = try generator.copyCGImage(
            at: CMTime(seconds: 1.4, preferredTimescale: 600), actualTime: nil)
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
        sample.draw(transitionFrame, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(Int(pixels[0]) > Int(pixels[1]) + 90)
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

    @Test func squarePlayerVideoAppliesOnlyOwnEffectsInsideCrop() async throws {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appending(path: "Fixtures/sample.mp4")
        let output = FileManager.default.temporaryDirectory
            .appending(path: "clip-editor-square-effects-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let attempts = [
            ClipAttempt(sourceTime: 1.1, text: nil, location: nil, player: "A|Player"),
            ClipAttempt(sourceTime: 1.4, text: nil, location: nil, player: "A|Player"),
            ClipAttempt(sourceTime: 1.7, text: nil, location: nil, player: "B|Other")
        ]
        let clip = Clip(start: 0.5, end: 2, descriptions: ["miss"], attempts: attempts)
        let frame = CGSize(width: 320, height: 180)
        var mask = Data(count: 320 * 180)
        for y in 40..<140 { for x in 80..<140 { mask[y * 320 + x] = 255 } }
        let bounds = [CGRect(x: 80, y: 40, width: 60, height: 100),
                      CGRect(x: 50, y: 40, width: 60, height: 100),
                      CGRect(x: 100, y: 40, width: 60, height: 100)]
        let effects = Dictionary(uniqueKeysWithValues: bounds.enumerated().map { index, box in
            let effect = AppliedShotEffect(timestamp: [1.0, 1.3, 1.6][index], bounds: box,
                frameSize: frame, maskPNG: Data(), maskPixels: mask, playerID: nil,
                playerName: "Player", shotDescription: "Jump Shot", shotLocation: nil)
            return (ShotEffectKey(clipID: clip.id, attemptIndex: index),
                    PreparedShotEffect(effect: effect, stats: LocalShotStats(makes: 5, attempts: 10),
                                       spotLabel: "Low Post"))
        })
        let settings = ShotEffectSettings(ellipseWidthMultiplier: 2, duration: 1.5)
        try await VideoCompilation.export(videoURL: fixture, clips: [clip], destination: output,
                                          title: "Player", player: "A|Player", square: true,
                                          shotEffects: effects, shotEffectSettings: settings)
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - (clip.end - clip.start + settings.duration)) < 0.15)
        let track = try #require(await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(abs(size.width - size.height) < 1)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let earlyFrame = try generator.copyCGImage(at: CMTime(seconds: 0.49, preferredTimescale: 600), actualTime: nil)
        let effectFrame = try generator.copyCGImage(at: CMTime(seconds: 0.9, preferredTimescale: 600), actualTime: nil)
        func brightness(_ image: CGImage, x: Int, y: Int) throws -> Int {
            let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
            let bytes = UnsafeMutablePointer<UInt8>.allocate(capacity: 4)
            defer { bytes.deallocate() }
            let context = try #require(CGContext(data: bytes, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return Int(bytes[0]) + Int(bytes[1]) + Int(bytes[2])
        }
        let earlyOutside = try brightness(earlyFrame, x: 5, y: 90)
        let darkOutside = try brightness(effectFrame, x: 5, y: 90)
        let earlyPlayer = try brightness(earlyFrame, x: 15, y: 90)
        let highlightedPlayer = try brightness(effectFrame, x: 15, y: 90)
        #expect(darkOutside < earlyOutside)
        #expect(abs(highlightedPlayer - earlyPlayer) < abs(darkOutside - earlyOutside))
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
