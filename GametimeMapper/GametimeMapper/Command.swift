import Foundation

@main
struct Command {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        var bottomDivisor = 1
        var rightDivisor = 1
        var leftDivisor = 1
        var seenOptions = Set<String>()
        var valid = arguments.count >= 2 && (arguments.count - 2).isMultiple(of: 2)
        if valid {
            for index in stride(from: 2, to: arguments.count, by: 2) {
                let option = arguments[index]
                guard (option == "--bottom-divisor" || option == "--right-divisor" || option == "--left-divisor"),
                      !seenOptions.contains(option),
                      let divisor = Int(arguments[index + 1]), divisor > 0 else {
                    valid = false
                    break
                }
                seenOptions.insert(option)
                if option == "--bottom-divisor" { bottomDivisor = divisor }
                else if option == "--right-divisor" { rightDivisor = divisor }
                else { leftDivisor = divisor }
            }
        }
        if seenOptions.contains("--left-divisor") && seenOptions.contains("--right-divisor") {
            valid = false
        }
        guard valid else {
            fputs("Usage: GametimeMapper <video-path> <output-json-path> [--bottom-divisor N] [--left-divisor N | --right-divisor N]\n", stderr)
            exit(2)
        }
        let videoURL = URL(fileURLWithPath: arguments[0])
        let outputURL = URL(fileURLWithPath: arguments[1])
        do {
            let entries = try await GameTimeMapper.map(videoURL: videoURL, outputURL: outputURL,
                                                       bottomDivisor: bottomDivisor,
                                                       rightDivisor: rightDivisor,
                                                       leftDivisor: leftDivisor,
                                                       log: { print($0) })
            print("Wrote \(entries.count) mapping ranges to \(outputURL.path)")
        } catch {
            fputs("GametimeMapper: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
