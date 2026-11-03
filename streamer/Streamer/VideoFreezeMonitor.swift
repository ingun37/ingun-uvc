import AVFoundation
import CoreVideo

/// Samples incoming video independently of the movie writer to detect stalled or repeated frames.
nonisolated final class VideoFreezeMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.streamer.freeze-monitor")
    private var onFreeze: @Sendable () -> Void = {}
    private var timer: DispatchSourceTimer?
    private var lastSignature: UInt64?
    private var lastChange = ProcessInfo.processInfo.systemUptime
    private var active = false

    override init() {
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func setOnFreeze(_ action: @escaping @Sendable () -> Void) {
        queue.async { self.onFreeze = action }
    }

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.active else { return }
            self.active = true
            self.lastSignature = nil
            self.lastChange = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.active,
                      ProcessInfo.processInfo.systemUptime - self.lastChange >= 10 else { return }
                self.active = false
                self.onFreeze()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.active = false
            self.timer?.cancel()
            self.timer = nil
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard active, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var signature: UInt64 = 14695981039346656037
        for row in 0..<16 {
            for column in 0..<16 {
                let offset = (row * height / 16) * stride + (column * width / 16) * 4
                for channel in 0..<3 {
                    signature = (signature ^ UInt64(bytes[offset + channel])) &* 1099511628211
                }
            }
        }
        if signature != lastSignature {
            lastSignature = signature
            lastChange = ProcessInfo.processInfo.systemUptime
        }
    }
}
