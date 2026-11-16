import ClockVideo
import Foundation

private let usage = """
Usage: mock-game-clock --width PIXELS --height PIXELS --code SCRIPT.txt --output VIDEO.mov

Width and height must be even numbers from 160 to 4096.
"""

private func run() throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments == ["--help"] || arguments == ["-h"] {
        print(usage)
        return
    }
    guard arguments.count == 8 else { throw CLIError.message(usage) }
    var options: [String: String] = [:]
    for index in stride(from: 0, to: arguments.count, by: 2) {
        let key = arguments[index]
        guard ["--width", "--height", "--code", "--output"].contains(key), options[key] == nil else {
            throw CLIError.message("Unknown or repeated argument: \(key)\n\(usage)")
        }
        options[key] = arguments[index + 1]
    }
    guard let widthText = options["--width"], let heightText = options["--height"],
          let width = Int(widthText), let height = Int(heightText),
          (160...4096).contains(width), (160...4096).contains(height),
          width.isMultiple(of: 2), height.isMultiple(of: 2) else {
        throw CLIError.message("Width and height must be even numbers from 160 to 4096 pixels.")
    }
    guard let codePath = options["--code"], let outputPath = options["--output"] else {
        throw CLIError.message(usage)
    }
    let codeURL = URL(fileURLWithPath: NSString(string: codePath).expandingTildeInPath)
    let outputURL = URL(fileURLWithPath: NSString(string: outputPath).expandingTildeInPath)
    guard outputURL.pathExtension.lowercased() == "mov" else {
        throw CLIError.message("Output path must end in .mov.")
    }
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw CLIError.message("Output already exists: \(outputURL.path)")
    }
    let source = try String(contentsOf: codeURL, encoding: .utf8)
    let script = try Script.parse(source)
    do {
        try VideoRenderer.renderWithFFmpeg(script, to: outputURL, size: CGSize(width: width, height: height)) { value in
            let percent = Int(value * 100)
            fputs("\rRendering \(percent)%", stderr)
            fflush(stderr)
        }
    } catch {
        try? FileManager.default.removeItem(at: outputURL)
        throw error
    }
    print("\nSaved \(outputURL.path)")
}

private enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case .message(let text) = self { return text }
        return nil
    }
}

do {
    try run()
} catch {
    fputs("Error: \(String(reflecting: error))\n", stderr)
    exit(EXIT_FAILURE)
}
