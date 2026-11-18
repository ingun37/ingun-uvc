import AVFoundation
import CoreImage
import CoreML
import AppKit

/// A recording-only, low-frequency consumer. The capture callback only swaps a retained frame.
nonisolated final class ThumbnailCandidateDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ingun37.GuraStreaming.thumbnails", qos: .background)
    private let lock = NSLock()
    private var waiting: (CVPixelBuffer, CMTime)?
    private var running = false
    private var active = false
    private var lastOffered: CMTime?
    private var origin: CMTime?
    private var directory: URL?
    private var log: [Candidate] = []
    private var imageModel: MLModel?
    private var positiveEmbeddings: [[Double]] = []
    private var negativeEmbeddings: [[Double]] = []
    private var positivePrompts: [String] = []
    private var negativePrompts: [String] = []
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private static let interval = 5.0
    func start(for movieURL: URL) {
        lock.lock()
        active = true
        waiting = nil
        lastOffered = nil
        origin = nil
        lock.unlock()
        queue.async { [self] in
            directory = movieURL.deletingLastPathComponent()
                .appendingPathComponent(movieURL.deletingPathExtension().lastPathComponent + "-thumbnail-candidates")
            log = []
            do { try prepareModel() }
            catch { print("Thumbnail detection unavailable: \(error.localizedDescription)") }
        }
    }

    func offer(_ frame: CVPixelBuffer, at time: CMTime) {
        guard time.isValid else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
        if let lastOffered, CMTimeSubtract(time, lastOffered).seconds < Self.interval {
            lock.unlock()
            return
        }
        if origin == nil { origin = time }
        lastOffered = time
        waiting = (frame, CMTimeSubtract(time, origin!))
        let shouldSchedule = !running
        if shouldSchedule { running = true }
        lock.unlock()
        if shouldSchedule { queue.async { [self] in process() } }
    }

    /// Runs after all queued inference and image writes, including an in-flight frame.
    func stopAccepting() {
        lock.lock()
        active = false
        waiting = nil
        lock.unlock()
    }

    /// Runs after all queued inference and image writes, including an in-flight frame.
    func finish(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        stopAccepting()
        queue.async { [self] in
            do {
                guard let directory else { throw ThumbnailError.noDirectory }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let csv = directory.appendingPathComponent("log.csv")
                let rows = ["video_timestamp,image_path,positive_score,positive_prompt,negative_score,negative_prompt,score_margin,top_1,top_2,top_3,top_4,top_5,bottom_1,bottom_2,bottom_3,bottom_4,bottom_5"]
                    + log.map { candidate in
                        let ranked = candidate.allScores.sorted { $0.score > $1.score }
                        let top = ranked.prefix(5).map(rankedField)
                        let bottom = ranked.suffix(5).reversed().map(rankedField)
                        let columns = [candidate.timestamp,
                                       csvField(candidate.url.path),
                                       scoreField(candidate.positive.score),
                                       csvField(candidate.positive.prompt),
                                       scoreField(candidate.negative.score),
                                       csvField(candidate.negative.prompt),
                                       scoreField(candidate.positive.score - candidate.negative.score)]
                            + top + Array(repeating: "", count: 5 - top.count)
                            + bottom + Array(repeating: "", count: 5 - bottom.count)
                        return columns.joined(separator: ",")
                    }
                try (rows.joined(separator: "\n") + "\n").write(to: csv, atomically: true, encoding: .utf8)
                completion(.success(csv))
            } catch { completion(.failure(error)) }
        }
    }

    private func process() {
        lock.lock()
        let item = waiting
        waiting = nil
        if item == nil { running = false }
        lock.unlock()
        guard let (frame, time) = item else { return }
        if imageModel != nil, !positiveEmbeddings.isEmpty, !negativeEmbeddings.isEmpty {
            do {
                let image = try embedding(for: frame)
                let positiveScores = try scores(for: image, embeddings: positiveEmbeddings,
                                                prompts: positivePrompts, group: "positive")
                let negativeScores = try scores(for: image, embeddings: negativeEmbeddings,
                                                prompts: negativePrompts, group: "negative")
                guard let good = positiveScores.max(by: { $0.score < $1.score }),
                      let bad = negativeScores.max(by: { $0.score < $1.score }) else {
                    throw ThumbnailError.invalidOutput
                }
                if good.score > bad.score {
                    try save(frame, at: time, positive: good, negative: bad,
                             allScores: positiveScores + negativeScores)
                }
            } catch { print("Thumbnail frame analysis failed: \(error.localizedDescription)") }
        }
        process()
    }

    private func prepareModel() throws {
        guard imageModel == nil else { return }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        guard let imageURL = Bundle.main.url(forResource: "clip-image", withExtension: "mlmodelc"),
              let promptsURL = Bundle.main.url(forResource: "clip-prompts", withExtension: "json") else {
            throw ThumbnailError.missingModel
        }
        let prompts = try JSONDecoder().decode(PromptEmbeddings.self, from: Data(contentsOf: promptsURL))
        guard !prompts.positive.isEmpty, !prompts.negative.isEmpty,
              prompts.positive.count == prompts.positivePrompts.count,
              prompts.negative.count == prompts.negativePrompts.count,
              (prompts.positive + prompts.negative).allSatisfy({ $0.count == 512 }) else {
            throw ThumbnailError.invalidOutput
        }
        positiveEmbeddings = prompts.positive
        negativeEmbeddings = prompts.negative
        positivePrompts = prompts.positivePrompts
        negativePrompts = prompts.negativePrompts
        imageModel = try MLModel(contentsOf: imageURL, configuration: config)
    }

    private func embedding(for frame: CVPixelBuffer) throws -> [Double] {
        guard let imageModel else { throw ThumbnailError.missingModel }
        let source = CIImage(cvPixelBuffer: frame)
        let side = min(source.extent.width, source.extent.height)
        let crop = source.cropped(to: CGRect(x: source.extent.midX - side / 2,
                                             y: source.extent.midY - side / 2,
                                             width: side, height: side))
        let resized = crop.transformed(by: CGAffineTransform(translationX: -crop.extent.minX, y: -crop.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: 224 / side, y: 224 / side))
        var input: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 224, 224, kCVPixelFormatType_32BGRA, nil, &input)
        guard status == kCVReturnSuccess, let input else { throw ThumbnailError.pixelBuffer }
        context.render(resized, to: input)
        let tensor = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        CVPixelBufferLockBaseAddress(input, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(input) else { throw ThumbnailError.pixelBuffer }
        let stride = CVPixelBufferGetBytesPerRow(input)
        let values = tensor.dataPointer.bindMemory(to: Float.self, capacity: 3 * 224 * 224)
        let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
        let deviation: [Float] = [0.26862954, 0.26130258, 0.27577711]
        for y in 0..<224 {
            let row = pixels.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<224 {
                let pixel = x * 4
                let index = y * 224 + x
                for channel in 0..<3 {
                    let component = Float(row[pixel + 2 - channel]) / 255
                    values[channel * 224 * 224 + index] = (component - mean[channel]) / deviation[channel]
                }
            }
        }
        let result = try imageModel.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": tensor]))
        guard let vector = result.featureValue(for: "embedding")?.multiArrayValue else {
            throw ThumbnailError.invalidOutput
        }
        return normalized(vector)
    }

    private func save(_ frame: CVPixelBuffer, at time: CMTime,
                      positive: PromptScore, negative: PromptScore,
                      allScores: [PromptScore]) throws {
        guard let directory else { throw ThumbnailError.noDirectory }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let seconds = max(0, time.seconds)
        let stamp = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), seconds)
        let url = directory.appendingPathComponent(stamp + ".jpg")
        guard let cgImage = context.createCGImage(CIImage(cvPixelBuffer: frame),
                                                  from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(frame),
                                                               height: CVPixelBufferGetHeight(frame))),
              let jpeg = NSBitmapImageRep(cgImage: cgImage)
                .representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else {
            throw ThumbnailError.jpeg
        }
        try jpeg.write(to: url, options: .atomic)
        log.append(Candidate(timestamp: stamp, url: url, positive: positive,
                             negative: negative, allScores: allScores))
        print("Thumbnail candidate at \(stamp)s: \(url.path) (\(positive.prompt): \(scoreField(positive.score)); \(negative.prompt): \(scoreField(negative.score)))")
    }

    private func normalized(_ array: MLMultiArray) -> [Double] {
        let values = (0..<array.count).map { array[$0].doubleValue }
        let length = sqrt(values.reduce(0) { $0 + $1 * $1 })
        return length > 0 ? values.map { $0 / length } : values
    }

    private func similarity(_ a: [Double], _ b: [Double]) -> Double {
        zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func scores(for image: [Double], embeddings: [[Double]], prompts: [String],
                        group: String) throws -> [PromptScore] {
        var scores: [PromptScore] = []
        for (embedding, prompt) in zip(embeddings, prompts) {
            let score = similarity(image, embedding)
            guard score.isFinite else { throw ThumbnailError.invalidOutput }
            scores.append(PromptScore(group: group, prompt: prompt, score: score))
        }
        guard !scores.isEmpty else { throw ThumbnailError.invalidOutput }
        return scores
    }

    private func scoreField(_ score: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), score)
    }

    private func rankedField(_ score: PromptScore) -> String {
        csvField("\(score.group): \(score.prompt) (\(scoreField(score.score)))")
    }

    private func csvField(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

nonisolated private struct PromptScore {
    let group: String
    let prompt: String
    let score: Double
}

nonisolated private struct Candidate {
    let timestamp: String
    let url: URL
    let positive: PromptScore
    let negative: PromptScore
    let allScores: [PromptScore]
}

nonisolated private struct PromptEmbeddings: Decodable {
    let positive: [[Double]]
    let negative: [[Double]]
    let positivePrompts: [String]
    let negativePrompts: [String]
}

private enum ThumbnailError: LocalizedError {
    case noDirectory, missingModel, invalidOutput, pixelBuffer, jpeg
    var errorDescription: String? {
        switch self {
        case .noDirectory: "Thumbnail output directory is unavailable."
        case .missingModel: "The CLIP Core ML model or prompt embeddings are missing from the app bundle."
        case .invalidOutput: "CLIP returned an invalid embedding."
        case .pixelBuffer: "Could not allocate a thumbnail model input."
        case .jpeg: "Could not encode the thumbnail candidate as JPEG."
        }
    }
}
