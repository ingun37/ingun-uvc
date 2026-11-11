import CoreImage
import CoreVideo
import ImageIO
import Testing
import Numerics

@testable import TheMapper

private final class FixtureBundleAnchor {}

struct TheMapperTests {
    @Test func bridgesShortFalsePauseWhenClockStayedContinuous() {
        let entries: [VideoTimeMapper.Interval] = [
            .init(kind: .continuous, period: "3RD", videoStart: 3030.5885961913264,
                  videoEnd: 3077.80739868156, gameStart: 597, gameEnd: 550),
            .init(kind: .paused, period: "3RD", videoStart: 3077.80739868156,
                  videoEnd: 3078.1651168822436, gameStart: 550, gameEnd: 550),
            .init(kind: .continuous, period: "3RD", videoStart: 3079.9537078856615,
                  videoEnd: 3086.392635497966, gameStart: 548, gameEnd: 541),
        ]
        #expect(VideoTimeMapper.merge(entries) == [
            .init(kind: .continuous, period: "3RD", videoStart: 3030.5885961913264,
                  videoEnd: 3086.392635497966, gameStart: 597, gameEnd: 541)
        ])
    }

    @Test func preservesLongRealPause() {
        let entries: [VideoTimeMapper.Interval] = [
            .init(kind: .continuous, period: "2ND", videoStart: 0, videoEnd: 5,
                  gameStart: 45, gameEnd: 40),
            .init(kind: .paused, period: "2ND", videoStart: 5, videoEnd: 8,
                  gameStart: 40, gameEnd: 40),
            .init(kind: .continuous, period: "2ND", videoStart: 8, videoEnd: 13,
                  gameStart: 40, gameEnd: 35),
        ]
        #expect(VideoTimeMapper.merge(entries) == entries)
    }

    @Test(arguments: ["continuous", "paused", "disappeared"])
    func mapsScoreboardVideo(name: String) async throws {
        let bundle = Bundle(for: FixtureBundleAnchor.self)
        let url = try #require(bundle.url(forResource: name, withExtension: "mp4"))
        let format = GameTimeReader.ScoreboardFormat(periodStyle: .short,
            underMinuteStyle: name == "paused" ? .colon : .doubleDigit)
        let intervals = try await VideoTimeMapper.map(videoURL: url, format: format)
        #expect(!intervals.isEmpty)
        #expect(intervals.allSatisfy { $0.videoStart < $0.videoEnd })
        if name == "continuous" {
            #expect(intervals.count == 1)
            #expect(intervals.first?.kind == .continuous)
            #expect(abs((intervals.first?.gameStart ?? 0) - 141) <= 1)
            #expect(abs((intervals.first?.gameEnd ?? 0) - 117) <= 1)
        } else if name == "paused" {
            #expect(intervals.contains { $0.kind == .paused })
            #expect(intervals.contains { $0.kind == .continuous })
            
            #expect(intervals.count == 6)
            
            #expect(floor(intervals[0].gameStart) == 42)
            #expect(floor(intervals[0].gameEnd) == 20)
            #expect(intervals[0].kind == .continuous)
            
            #expect(floor(intervals[1].gameStart) == 20)
            #expect(floor(intervals[1].gameEnd) == 20)
            #expect(intervals[1].kind == .paused)
            
            #expect(floor(intervals[2].gameStart) == 20)
            #expect(intervals[2].gameEnd.isApproximatelyEqual(to: 1.4, absoluteTolerance: 0.001))
            #expect(intervals[2].kind == .continuous)
            
            #expect(intervals[3].gameStart.isApproximatelyEqual(to: 1.4, absoluteTolerance: 0.001))
            #expect(intervals[3].gameEnd.isApproximatelyEqual(to: 1.4, absoluteTolerance: 0.001))
            #expect(intervals[3].kind == .paused)
            
            #expect(intervals[4].gameStart.isApproximatelyEqual(to: 1.4, absoluteTolerance: 0.001))
            #expect(intervals[4].gameEnd == 0)
            #expect(intervals[4].kind == .continuous)
            #expect(intervals[5].gameStart == 0)
            #expect(intervals[5].gameEnd == 0)
            #expect(intervals[5].kind == .paused)
        } else {
            #expect(intervals.count == 2)
            if intervals.count == 2 {
                #expect(intervals[0].kind == .continuous)
                #expect(intervals[0].gameStart == 627)
                #expect(intervals[0].gameEnd == 623)
                #expect(intervals[1].kind == .paused)
                #expect(intervals[1].gameStart == 623)
                #expect(intervals[1].gameEnd == 623)
            }
        }
    }

    @Test func doubleDigitUnderMinuteClock() {
        let format = GameTimeReader.ScoreboardFormat(periodStyle: .short,
                                                      underMinuteStyle: .doubleDigit)
        #expect(GameTimeReader.parse(["2ND", "16.1"], format: format) ==
                .init(period: "2ND", gameSecond: 16.1))
        #expect(GameTimeReader.parse(["2ND", "06.1"], format: format) ==
                .init(period: "2ND", gameSecond: 6.1))
        #expect(GameTimeReader.parse(["2ND", "06.0"], format: format) ==
                .init(period: "2ND", gameSecond: 6))
        #expect(GameTimeReader.parse(["2ND", "6.1"], format: format) == nil)
        #expect(GameTimeReader.parse(["2ND", ":06.1"], format: format) == nil)
        #expect(GameTimeReader.parse(["2ND", "06"], format: format) == nil)
        #expect(GameTimeReader.parse(["2ND", "1:16"], format: format) ==
                .init(period: "2ND", gameSecond: 76))
    }

    // Placeholder answers. Edit these values when you label the images.
    // Add one row whenever you add a PNG fixture.
    private static let presetA: [(fileTime: String, period: String, seconds: Double)] = [
        ("4.13.32", "2ND", 8*60+12),
        ("4.13.50", "2ND", 16.3),
        ("4.14.02", "2ND", 4.4),
        ("4.14.21", "3RD", 10*60+29),
        ("4.14.30", "3RD", 4*60+23),
        ("4.14.46", "3RD", 22.2),
        ("4.14.57", "3RD", 5.1),
        ("4.15.11", "4TH", 10*60+38),
        ("4.15.23", "4TH", 2*60+50),
        ("4.15.37", "4TH", 48.4),
    ]

    private static let presetC: [(fileTime: String, period: String, seconds: Double)] = [
        ("4.18.16", "3RD", 7*60+2),
        ("4.18.33", "4TH", 4.6),
    ]

    @Test func presetAImages() throws {
        try checkFixtures(format: .init(periodStyle: .short,
            underMinuteStyle: .colon), answers: Self.presetA)
    }

    @Test func presetCImages() throws {
        try checkFixtures(format: .init(periodStyle: .short,
            underMinuteStyle: .natural), answers: Self.presetC)
    }

    private func checkFixtures(format: GameTimeReader.ScoreboardFormat,
                               answers: [(fileTime: String, period: String, seconds: Double)]) throws {
        let root = try #require(Bundle(for: FixtureBundleAnchor.self).resourceURL)
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let urls = enumerator.allObjects.compactMap { $0 as? URL }.filter {
            $0.pathExtension.lowercased() == "png"
        }
        #expect(urls.count == Self.presetA.count + Self.presetC.count,
                "Add an expected-answer row for every new PNG fixture")
        for answer in answers {
            let url = try #require(urls.first { $0.lastPathComponent.contains(answer.fileTime) },
                                   "Missing fixture for \(answer.fileTime)")
            let buffer = try pixelBuffer(from: url)
            let reading = try #require(try GameTimeReader.read(buffer, format: format),
                                       "No reading from \(url.lastPathComponent)")
            #expect(reading.period == answer.period, "\(url.lastPathComponent)")
            #expect(reading.gameSecond == answer.seconds, "\(url.lastPathComponent)")
        }
    }

    private func pixelBuffer(from url: URL) throws -> CVPixelBuffer {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                         kCVPixelFormatType_32BGRA, attributes, &buffer)
        #expect(status == kCVReturnSuccess)
        let result = try #require(buffer)
        CIContext().render(CIImage(cgImage: image), to: result)
        return result
    }
}
