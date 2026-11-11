import CoreImage
import CoreVideo
import ImageIO
import Testing
@testable import TheMapper

private final class FixtureBundleAnchor {}

struct TheMapperTests {
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
