import AVFoundation
import CoreVideo
import Metal

/// Compares every video pixel on the GPU without copying capture frames into a new texture.
nonisolated final class VideoFreezeMonitor: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "dev.streamer.freeze-monitor")
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var onFreeze: @Sendable () -> Void = {}
    private var timer: DispatchSourceTimer?
    private var previous: CVMetalTexture?
    private var comparing = false
    private var lastChange = ProcessInfo.processInfo.systemUptime
    private var active = false

    init?(metalDevice: MTLDevice?) {
        guard let device = metalDevice,
              let commandQueue = device.makeCommandQueue() else { return nil }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void compareFrames(texture2d<float, access::read> current [[texture(0)]],
                                  texture2d<float, access::read> previous [[texture(1)]],
                                  device atomic_uint *changed [[buffer(0)]],
                                  uint2 position [[thread_position_in_grid]],
                                  uint lane [[thread_index_in_threadgroup]]) {
            threadgroup atomic_uint groupChanged;
            if (lane == 0) atomic_store_explicit(&groupChanged, 0, memory_order_relaxed);
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (position.x < current.get_width() && position.y < current.get_height()) {
                float4 a = current.read(position);
                float4 b = previous.read(position);
                if (any(a.rgb != b.rgb))
                    atomic_store_explicit(&groupChanged, 1, memory_order_relaxed);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (lane == 0 && atomic_load_explicit(&groupChanged, memory_order_relaxed) != 0)
                atomic_store_explicit(changed, 1, memory_order_relaxed);
        }
        """
        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "compareFrames") else { return nil }
            pipeline = try device.makeComputePipelineState(function: function)
        } catch { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        textureCache = cache
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
            guard let self, !self.active else { return }
            self.active = true
            self.previous = nil
            self.lastChange = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in
                guard let self, self.active, !self.comparing,
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
            self.previous = nil
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard active, !comparing, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapped: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil,
                .bgra8Unorm, width, height, 0, &wrapped) == kCVReturnSuccess,
              let current = wrapped, let currentTexture = CVMetalTextureGetTexture(current) else {
            // An unsupported capture buffer must not be mistaken for a frozen picture.
            lastChange = ProcessInfo.processInfo.systemUptime
            previous = nil
            return
        }
        guard let prior = previous, let priorTexture = CVMetalTextureGetTexture(prior),
              priorTexture.width == width, priorTexture.height == height else {
            previous = current
            lastChange = ProcessInfo.processInfo.systemUptime
            return
        }
        guard let result = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let command = commandQueue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            previous = nil
            lastChange = ProcessInfo.processInfo.systemUptime
            return
        }
        result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(currentTexture, index: 0)
        encoder.setTexture(priorTexture, index: 1)
        encoder.setBuffer(result, offset: 0, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
        comparing = true
        let submittedAt = ProcessInfo.processInfo.systemUptime
        command.addCompletedHandler { [weak self, current, prior, result] finished in
            // Retain both Core Video wrappers until the GPU is done reading their IOSurfaces.
            withExtendedLifetime((current, prior)) {
                self?.queue.async { [weak self, current, result] in
                    guard let self else { return }
                    self.comparing = false
                    guard self.active else { return }
                    if finished.status != .completed {
                        self.previous = nil
                        self.lastChange = ProcessInfo.processInfo.systemUptime
                    } else {
                        self.previous = current
                        if result.contents().load(as: UInt32.self) != 0 {
                            self.lastChange = submittedAt
                        }
                    }
                }
            }
        }
        command.commit()
    }
}
