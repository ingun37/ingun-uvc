import AVFoundation
import Observation

@Observable
final class AudioLevelMeter {
    var level: Double = 0
}

/// Retaining one sample buffer is all the AVFoundation callback does. Analysis
/// and UI updates run on other queues, and older waiting buffers are dropped.
nonisolated final class AudioLevelProcessor: @unchecked Sendable {
    let meter: AudioLevelMeter
    let silenceDetector: AudioSilenceDetector
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.ingun37.GuraStreaming.audioLevels", qos: .utility)
    private var waitingBuffer: CMSampleBuffer?
    private var active = false
    private var lastPublished = 0.0

    init(meter: AudioLevelMeter, silenceDetector: AudioSilenceDetector) {
        self.meter = meter
        self.silenceDetector = silenceDetector
    }

    func offer(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        waitingBuffer = sampleBuffer
        let shouldStart = !active
        if shouldStart { active = true }
        lock.unlock()
        if shouldStart { queue.async { [self] in processLatest() } }
    }

    private func processLatest() {
        lock.lock()
        let sampleBuffer = waitingBuffer
        waitingBuffer = nil
        if sampleBuffer == nil { active = false }
        lock.unlock()
        guard let sampleBuffer else { return }

        if let rms = rmsLevel(sampleBuffer) {
            if rms > 0.01 { silenceDetector.heardSound() }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastPublished >= 0.05 {
                lastPublished = now
                let level = min(1, sqrt(rms) * 1.8)
                Task { @MainActor [meter] in meter.level = level }
            }
        }
        queue.async { [self] in processLatest() }
    }

    private func rmsLevel(_ sampleBuffer: CMSampleBuffer) -> Double? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &length,
                                          totalLengthOut: nil, dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let pointer, length >= MemoryLayout<Float>.size else { return nil }
        // The output is configured for interleaved Float32 PCM. Limit work to
        // at most 256 samples even for a large audio buffer.
        let count = min(length / MemoryLayout<Float>.size, 256)
        let samples = UnsafeRawPointer(pointer).assumingMemoryBound(to: Float.self)
        var sum = 0.0
        for index in 0..<count {
            let value = Double(samples[index])
            sum += value * value
        }
        let rms = sqrt(sum / Double(count))
        return rms
    }
}

nonisolated final class AudioLevelDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let processor: AudioLevelProcessor

    init(processor: AudioLevelProcessor) { self.processor = processor }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        processor.offer(sampleBuffer)
    }
}
