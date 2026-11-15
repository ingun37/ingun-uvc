import AVFoundation
import Metal

/// Compares the newest waiting frame on a worker queue. Capture callbacks only replace a slot.
nonisolated final class MetalFreezeDetector: @unchecked Sendable {
    private let renderer: MetalPreviewRenderer
    private let pipeline: MTLComputePipelineState
    private let queue = DispatchQueue(label: "com.ingun37.GuraStreaming.freeze", qos: .userInitiated)
    private let lock = NSLock()
    private var waiting: (CVPixelBuffer, CMTime)?
    private var active = false
    private var running = false
    private var previous: CVPixelBuffer?
    private var frozenSince: CMTime?
    private var lastRemaining: Int?
    var onCountdown: (@Sendable (Int?) -> Void)?
    var onTimeout: (@Sendable () -> Void)?
    var timeout: TimeInterval = 60

    init(renderer: MetalPreviewRenderer) throws {
        self.renderer = renderer
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void compareFrames(texture2d<float, access::read> a [[texture(0)]],
                                  texture2d<float, access::read> b [[texture(1)]],
                                  device atomic_uint *difference [[buffer(0)]],
                                  uint id [[thread_position_in_grid]]) {
            if (id >= 36864) return;
            uint2 p = uint2((id % 256) * a.get_width() / 256,
                            (id / 256) * a.get_height() / 144);
            float4 x = a.read(p), y = b.read(p);
            uint delta = uint(round(abs(x.r-y.r)*255.0)) +
                         uint(round(abs(x.g-y.g)*255.0)) +
                         uint(round(abs(x.b-y.b)*255.0));
            atomic_fetch_add_explicit(difference, delta, memory_order_relaxed);
        }
        """
        let library = try renderer.device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "compareFrames") else { throw FreezeError.shader }
        pipeline = try renderer.device.makeComputePipelineState(function: function)
    }

    func setActive(_ value: Bool) {
        lock.lock()
        active = value
        waiting = nil
        lock.unlock()
        queue.async { [self] in
            previous = nil
            frozenSince = nil
            lastRemaining = nil
            onCountdown?(nil)
        }
    }

    func offer(_ frame: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        guard active else { lock.unlock(); return }
        waiting = (frame, time)
        let start = !running
        if start { running = true }
        lock.unlock()
        if start { queue.async { [self] in process() } }
    }

    private func process() {
        lock.lock()
        let item = waiting
        waiting = nil
        if item == nil { running = false }
        lock.unlock()
        guard let (frame, time) = item else { return }
        if let previous, let repeated = compare(previous, frame) {
            if repeated {
                if frozenSince == nil { frozenSince = time }
                let elapsed = max(0, CMTimeSubtract(time, frozenSince!).seconds)
                let remaining = max(0, Int(ceil(timeout - elapsed)))
                if remaining != lastRemaining {
                    lastRemaining = remaining
                    onCountdown?(remaining)
                }
                if elapsed >= timeout {
                    lock.lock(); active = false; waiting = nil; lock.unlock()
                    onTimeout?()
                }
            } else {
                frozenSince = nil
                if lastRemaining != nil { lastRemaining = nil; onCountdown?(nil) }
            }
        }
        previous = frame
        process()
    }

    private func compare(_ a: CVPixelBuffer, _ b: CVPixelBuffer) -> Bool? {
        guard CVPixelBufferGetWidth(a) == CVPixelBufferGetWidth(b),
              CVPixelBufferGetHeight(a) == CVPixelBufferGetHeight(b),
              CVPixelBufferGetPixelFormatType(a) == CVPixelBufferGetPixelFormatType(b) else { return false }
        let format = CVPixelBufferGetPixelFormatType(a) == kCVPixelFormatType_32BGRA ? MTLPixelFormat.bgra8Unorm : .r8Unorm
        guard let first = renderer.texture(a, format: format, plane: 0),
              let second = renderer.texture(b, format: format, plane: 0),
              let firstTexture = CVMetalTextureGetTexture(first),
              let secondTexture = CVMetalTextureGetTexture(second),
              let result = renderer.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let command = renderer.commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else { return nil }
        result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(firstTexture, index: 0)
        encoder.setTexture(secondTexture, index: 1)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: 36864, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        // Allow small codec noise; a changing picture differs by much more than two levels per sample.
        return result.contents().load(as: UInt32.self) <= 36864 * (format == .bgra8Unorm ? 6 : 2)
    }
}

private enum FreezeError: Error { case shader }
