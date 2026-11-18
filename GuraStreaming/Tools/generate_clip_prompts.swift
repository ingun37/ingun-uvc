import CoreML
import Foundation

private struct TokenInput: Decodable {
    let positivePrompts: [String]
    let negativePrompts: [String]
    let positiveTokens: [[Int]]
    let negativeTokens: [[Int]]
}

private struct PromptOutput: Encodable {
    let positivePrompts: [String]
    let negativePrompts: [String]
    let positive: [[Double]]
    let negative: [[Double]]
}

@main
struct GenerateCLIPPrompts {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else {
            throw GeneratorError.usage
        }
        let modelURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let tokensURL = URL(fileURLWithPath: CommandLine.arguments[2])
        let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let input = try JSONDecoder().decode(TokenInput.self, from: Data(contentsOf: tokensURL))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)

        func embed(_ tokens: [Int]) throws -> [Double] {
            guard tokens.count == 77 else { throw GeneratorError.tokenCount }
            let array = try MLMultiArray(shape: [1, 77], dataType: .int32)
            for (index, token) in tokens.enumerated() {
                array[index] = NSNumber(value: token)
            }
            let prediction = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["input_ids": array]))
            guard let embedding = prediction.featureValue(for: "embedding")?.multiArrayValue,
                  embedding.count == 512 else {
                throw GeneratorError.embedding
            }
            let values = (0..<embedding.count).map { embedding[$0].doubleValue }
            let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
            guard length.isFinite, length > 0 else { throw GeneratorError.embedding }
            return values.map { $0 / length }
        }

        let result = try PromptOutput(
            positivePrompts: input.positivePrompts,
            negativePrompts: input.negativePrompts,
            positive: input.positiveTokens.map(embed),
            negative: input.negativeTokens.map(embed)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(result)
        try data.write(to: outputURL, options: .atomic)
        print("Updated \(outputURL.path) (\(result.positive.count) positive, \(result.negative.count) negative prompts)")
    }
}

private enum GeneratorError: LocalizedError {
    case usage, tokenCount, embedding
    var errorDescription: String? {
        switch self {
        case .usage: "Usage: generate_clip_prompts <compiled-text-model> <token-json> <output-json>"
        case .tokenCount: "A CLIP prompt must contain exactly 77 padded token IDs."
        case .embedding: "The CLIP text encoder returned an invalid embedding."
        }
    }
}
