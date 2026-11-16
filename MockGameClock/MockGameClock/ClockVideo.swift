import AVFoundation
import AppKit
import CoreVideo

struct GameClock: Comparable {
    static let periods = ["1ST", "2ND", "3RD", "4TH", "OT", "2OT", "3OT"]
    let period: Int
    let centiseconds: Int

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.period != rhs.period ? lhs.period < rhs.period : lhs.centiseconds > rhs.centiseconds
    }

    var label: String { Self.periods[period] }
    var display: String {
        if centiseconds >= 6000 {
            return String(format: "%02d:%02d", centiseconds / 6000, (centiseconds / 100) % 60)
        }
        return String(format: ":%02d.%d", (centiseconds / 100) % 60, (centiseconds % 100) / 10)
    }

    var next: Self? {
        if centiseconds > 0 { return Self(period: period, centiseconds: max(0, centiseconds - 1)) }
        guard period < 6 else { return nil }
        return Self(period: period + 1, centiseconds: period < 3 ? 12 * 6000 - 100 : 5 * 6000 - 100)
    }

    static func parse(_ value: String) -> Self? {
        let parts = value.uppercased().split(separator: " ")
        guard parts.count == 2, let period = periods.firstIndex(of: String(parts[0])) else { return nil }
        let time = parts[1].split(whereSeparator: { $0 == ":" || $0 == "." })
        guard time.count == 3,
              time.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isNumber) }),
              let minute = Int(time[0]), let second = Int(time[1]), let fraction = Int(time[2]),
              minute < (period < 4 ? 12 : 5), second < 60, fraction < 100 else { return nil }
        return Self(period: period, centiseconds: (minute * 60 + second) * 100 + fraction)
    }
}

private enum Instruction {
    case start(GameClock)
    case pause(GameClock, Double)
    case hide(GameClock, Double)
    case end(GameClock)
}

public struct Script {
    let start: GameClock
    let events: [(clock: GameClock, duration: Double, hidden: Bool)]
    let end: GameClock

    public static func parse(_ source: String) throws -> Self {
        var instructions: [Instruction] = []
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let words = line.split(separator: " ").map(String.init)
            let action = words.first?.lowercased() ?? ""
            let time: String
            if action == "start" && words.count == 4 && words[1].lowercased() == "at" { time = words[2] + " " + words[3] }
            else if action == "end" && words.count == 4 && words[1].lowercased() == "at" { time = words[2] + " " + words[3] }
            else if (action == "pause" || action == "hide") && words.count == 7 && words[1].lowercased() == "at" && words[4].lowercased() == "for" && words[6].lowercased() == "seconds" {
                time = words[2] + " " + words[3]
            } else { throw ParseError.message("Line \(index + 1): invalid statement") }
            guard let clock = GameClock.parse(time) else { throw ParseError.message("Line \(index + 1): invalid clock time") }
            switch action {
            case "start": instructions.append(.start(clock))
            case "end": instructions.append(.end(clock))
            default:
                guard let duration = Double(words[5]), duration.isFinite, duration > 0 else { throw ParseError.message("Line \(index + 1): duration must be positive") }
                instructions.append(action == "pause" ? .pause(clock, duration) : .hide(clock, duration))
            }
        }
        guard case .start(let start)? = instructions.first, case .end(let end)? = instructions.last else {
            throw ParseError.message("Start with ‘start at’ and finish with ‘end at’.")
        }
        guard start <= end else { throw ParseError.message("End must be after start in game time.") }
        var events: [(GameClock, Double, Bool)] = []
        var previous = start
        for instruction in instructions.dropFirst().dropLast() {
            let clock: GameClock
            let duration: Double
            let hidden: Bool
            switch instruction {
            case .pause(let c, let d): clock = c; duration = d; hidden = false
            case .hide(let c, let d): clock = c; duration = d; hidden = true
            default: throw ParseError.message("Only pause or hide can appear between start and end.")
            }
            guard clock >= previous && clock <= end else { throw ParseError.message("Events must follow game-clock order and precede the end.") }
            events.append((clock, duration, hidden))
            previous = clock
        }
        return Self(start: start, events: events, end: end)
    }
}

private enum ParseError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

public enum VideoRenderer {
    static let fps: Int32 = 30
    private static let layoutSize = CGSize(width: 1280, height: 720)

    public static func render(_ script: Script, to url: URL, size: CGSize, progress: @escaping (Double) -> Void) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height)
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ParseError.message("Could not start video writer.") }
        writer.startSession(atSourceTime: .zero)
        var frame: Int64 = 0
        var elapsedCentiseconds: Int64 = 0
        var current = script.start
        var eventIndex = 0
        let totalTicks = estimateTicks(script)

        func append(_ clock: GameClock, hidden: Bool) throws {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
            guard let pool = adaptor.pixelBufferPool else { throw ParseError.message("Video pixel buffer pool unavailable.") }
            var buffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer else { throw ParseError.message("Could not allocate a video frame.") }
            draw(clock: clock, hidden: hidden, in: buffer, size: size)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps)) else {
                throw writer.error ?? ParseError.message("Could not write a video frame.")
            }
            frame += 1
            if frame % 90 == 0 { progress(min(1, Double(frame) / Double(totalTicks))) }
        }

        while true {
            while eventIndex < script.events.count && script.events[eventIndex].clock == current {
                let event = script.events[eventIndex]
                let frames = max(1, Int((event.duration * Double(fps)).rounded()))
                for _ in 0..<frames { try append(current, hidden: event.hidden) }
                eventIndex += 1
            }
            if elapsedCentiseconds == 0 || (elapsedCentiseconds * 30 / 100) > ((elapsedCentiseconds - 1) * 30 / 100) || current == script.end {
                try append(current, hidden: false)
            }
            if current == script.end { break }
            guard let next = current.next else { throw ParseError.message("Clock ended before the requested end time.") }
            current = next
            elapsedCentiseconds += 1
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw writer.error ?? ParseError.message("Video export failed.") }
        progress(1)
    }

    public static func renderWithFFmpeg(_ script: Script, to url: URL, size: CGSize, progress: @escaping (Double) -> Void) throws {
        let width = Int(size.width)
        let height = Int(size.height)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "rawvideo", "-pixel_format", "argb",
                             "-video_size", "\(width)x\(height)", "-framerate", "30", "-i", "pipe:0",
                             "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-movflags", "+faststart", url.path]
        let pipe = Pipe()
        process.standardInput = pipe
        try process.run()
        var frame: Int64 = 0
        var elapsedCentiseconds: Int64 = 0
        var current = script.start
        var eventIndex = 0
        let totalFrames = estimateTicks(script)
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ]

        func append(_ clock: GameClock, hidden: Bool) throws {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &buffer) == kCVReturnSuccess,
                  let buffer else { throw ParseError.message("Could not allocate a video frame.") }
            draw(clock: clock, hidden: hidden, in: buffer, size: size)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ParseError.message("Could not read a video frame.") }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for row in 0..<height {
                try pipe.fileHandleForWriting.write(contentsOf: Data(bytes: base.advanced(by: row * stride), count: width * 4))
            }
            frame += 1
            if frame % 90 == 0 { progress(min(1, Double(frame) / Double(totalFrames))) }
        }

        do {
            while true {
                while eventIndex < script.events.count && script.events[eventIndex].clock == current {
                    let event = script.events[eventIndex]
                    let frames = max(1, Int((event.duration * Double(fps)).rounded()))
                    for _ in 0..<frames { try append(current, hidden: event.hidden) }
                    eventIndex += 1
                }
                if elapsedCentiseconds == 0 || (elapsedCentiseconds * 30 / 100) > ((elapsedCentiseconds - 1) * 30 / 100) || current == script.end {
                    try append(current, hidden: false)
                }
                if current == script.end { break }
                guard let next = current.next else { throw ParseError.message("Clock ended before the requested end time.") }
                current = next
                elapsedCentiseconds += 1
            }
            try pipe.fileHandleForWriting.close()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw ParseError.message("ffmpeg failed with exit status \(process.terminationStatus).") }
            progress(1)
        } catch {
            try? pipe.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
    }

    private static func estimateTicks(_ script: Script) -> Int64 {
        var ticks: Int64 = 1
        var current = script.start
        while current != script.end, let next = current.next { ticks += 1; current = next }
        return ticks * 30 / 100 + 1 + Int64(script.events.reduce(0) { $0 + Int(($1.duration * Double(fps)).rounded()) })
    }

    private static func draw(clock: GameClock, hidden: Bool, in buffer: CVPixelBuffer, size: CGSize) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) else { return }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        guard !hidden else { return }
        let scale = min(size.width / layoutSize.width, size.height / layoutSize.height)
        context.translateBy(x: (size.width - layoutSize.width * scale) / 2,
                            y: (size.height - layoutSize.height * scale) / 2)
        context.scaleBy(x: scale, y: scale)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let white = NSColor.white
        let period = NSAttributedString(string: clock.label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 86, weight: .bold), .foregroundColor: white, .paragraphStyle: paragraph
        ])
        let time = NSAttributedString(string: clock.display, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 230, weight: .bold), .foregroundColor: white, .paragraphStyle: paragraph
        ])
        let graphics = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        period.draw(in: CGRect(x: 0, y: 425, width: layoutSize.width, height: 110))
        time.draw(in: CGRect(x: 0, y: 205, width: layoutSize.width, height: 280))
        NSGraphicsContext.restoreGraphicsState()
    }
}

