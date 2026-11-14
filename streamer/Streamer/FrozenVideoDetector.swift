import AVFoundation
import Metal

nonisolated private final class PendingFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    init(_ pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

nonisolated private final class PendingComparison: @unchecked Sendable {
    let current: CVMetalTexture
    let previous: CVMetalTexture
    let result: MTLBuffer
    let time: TimeInterval
    let previousTime: TimeInterval

    init(current: CVMetalTexture, previous: CVMetalTexture, result: MTLBuffer,
         time: TimeInterval, previousTime: TimeInterval) {
        self.current = current
        self.previous = previous
        self.result = result
        self.time = time
        self.previousTime = previousTime
    }
}

/// Samples at most twice a second. GPU work and readback never block the capture frame queue.
nonisolated final class FrozenVideoDetector: @unchecked Sendable {
    private static let sampleWidth = 64
    private static let sampleHeight = 36
    private static let sampleInterval: TimeInterval = 0.5
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache
    private let workQueue = DispatchQueue(label: "dev.streamer.freeze", qos: .utility)
    private let lock = NSLock()
    private var lastSampleTime: TimeInterval?
    private var previousTexture: CVMetalTexture?
    private var previousTime: TimeInterval?
    private var freezeStart: TimeInterval?
    private var inFlight = false
    private var cancelled = false

    init(device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else { throw CaptureFailure.metalUnavailable }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void frameDifference(texture2d<float, access::read> current [[texture(0)]],
                                    texture2d<float, access::read> previous [[texture(1)]],
                                    device atomic_uint *total [[buffer(0)]],
                                    uint2 id [[thread_position_in_grid]]) {
            if (id.x >= 64 || id.y >= 36) return;
            uint2 a = uint2((id.x * current.get_width()) / 64,
                            (id.y * current.get_height()) / 36);
            uint2 b = uint2((id.x * previous.get_width()) / 64,
                            (id.y * previous.get_height()) / 36);
            float3 delta = abs(current.read(a).rgb - previous.read(b).rgb);
            uint difference = uint(round((delta.r + delta.g + delta.b) * (1024.0 / 3.0)));
            atomic_fetch_add_explicit(total, difference, memory_order_relaxed);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "frameDifference") else { throw CaptureFailure.metalUnavailable }
        pipeline = try device.makeComputePipelineState(function: function)
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw CaptureFailure.metalUnavailable }
        textureCache = cache
        self.commandQueue = commandQueue
    }

    /// Returns false when a frame is skipped. Accepted frames call `completion` after GPU work finishes.
    @discardableResult
    func inspect(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval,
                 completion: @escaping @Sendable (TimeInterval?) -> Void) -> Bool {
        lock.lock()
        guard !cancelled, !inFlight,
              lastSampleTime.map({ time - $0 >= Self.sampleInterval }) ?? true else {
            lock.unlock()
            return false
        }
        lastSampleTime = time
        inFlight = true
        lock.unlock()

        let frame = PendingFrame(pixelBuffer)
        workQueue.async { [self] in process(frame, at: time, completion: completion) }
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        previousTexture = nil
        lock.unlock()
    }

    private func process(_ frame: PendingFrame, at time: TimeInterval,
                         completion: @escaping @Sendable (TimeInterval?) -> Void) {
        lock.lock()
        let shouldProcess = !cancelled
        lock.unlock()
        guard shouldProcess else {
            finishWithoutComparison(completion)
            return
        }
        var image: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame.pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(frame.pixelBuffer), CVPixelBufferGetHeight(frame.pixelBuffer), 0, &image
        ) == kCVReturnSuccess, let image else {
            finishWithoutComparison(completion)
            return
        }

        lock.lock()
        let previous = previousTexture
        let previousTime = self.previousTime
        if previous == nil && !cancelled {
            previousTexture = image
            self.previousTime = time
        }
        lock.unlock()
        guard let previous, let previousTime else {
            finishWithoutComparison(completion, reset: false)
            return
        }

        guard let currentTexture = CVMetalTextureGetTexture(image),
              let previousTexture = CVMetalTextureGetTexture(previous),
              let result = commandQueue.device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            finishWithoutComparison(completion)
            return
        }
        result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(previousTexture, index: 1)
        encoder.setBuffer(result, offset: 0, index: 0)
        encoder.dispatchThreads(MTLSize(width: Self.sampleWidth, height: Self.sampleHeight, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        let pending = PendingComparison(current: image, previous: previous, result: result,
                                        time: time, previousTime: previousTime)
        command.addCompletedHandler { [self] finished in
            complete(pending, succeeded: finished.status == .completed, completion: completion)
        }
        command.commit()
    }

    private func finishWithoutComparison(_ completion: @Sendable (TimeInterval?) -> Void,
                                         reset: Bool = true) {
        lock.lock()
        if reset {
            previousTexture = nil
            previousTime = nil
            freezeStart = nil
        }
        inFlight = false
        let shouldNotify = !cancelled
        lock.unlock()
        if shouldNotify { completion(nil) }
    }

    private func complete(_ pending: PendingComparison, succeeded: Bool,
                          completion: @Sendable (TimeInterval?) -> Void) {
        let averageDifference = succeeded
            ? Double(pending.result.contents().load(as: UInt32.self)) /
                Double(Self.sampleWidth * Self.sampleHeight * 1024)
            : .infinity
        lock.lock()
        let shouldNotify = !cancelled
        if shouldNotify {
            previousTexture = pending.current
            previousTime = pending.time
            if averageDifference < 0.008, pending.time >= pending.previousTime {
                if freezeStart == nil { freezeStart = pending.previousTime }
            } else {
                freezeStart = nil
            }
        }
        let duration = freezeStart.map { pending.time - $0 }
        inFlight = false
        lock.unlock()
        if shouldNotify { completion(duration) }
    }
}
