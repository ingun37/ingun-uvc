import Foundation

@main
struct Command {
    static func main() async {
        guard CommandLine.arguments.count == 3 else {
            fputs("Usage: GametimeMapper <video-path> <output-json-path>\n", stderr)
            exit(2)
        }
        let videoURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
        do {
            let entries = try await GameTimeMapper.map(videoURL: videoURL, outputURL: outputURL,
                                                       log: { print($0) })
            print("Wrote \(entries.count) mapping ranges to \(outputURL.path)")
        } catch {
            fputs("GametimeMapper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
