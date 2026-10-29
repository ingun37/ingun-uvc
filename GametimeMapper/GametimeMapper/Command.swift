import Foundation

@main
struct Command {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let bottomDivisor = arguments.count == 4 ? (Int(arguments[3]) ?? 0) : 1
        guard arguments.count == 2 || arguments.count == 4,
              arguments.count == 2 || arguments[2] == "--bottom-divisor",
              bottomDivisor > 0 else {
            fputs("Usage: GametimeMapper <video-path> <output-json-path> [--bottom-divisor N]\n", stderr)
            exit(2)
        }
        let videoURL = URL(fileURLWithPath: arguments[0])
        let outputURL = URL(fileURLWithPath: arguments[1])
        do {
            let entries = try await GameTimeMapper.map(videoURL: videoURL, outputURL: outputURL,
                                                       bottomDivisor: bottomDivisor,
                                                       log: { print($0) })
            print("Wrote \(entries.count) mapping ranges to \(outputURL.path)")
        } catch {
            fputs("GametimeMapper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
