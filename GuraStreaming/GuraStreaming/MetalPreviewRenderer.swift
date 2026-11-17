import CoreVideo
import AppKit
import Metal
import QuartzCore

/// Retains the capture storage until the GPU completion callback runs.
nonisolated private final class FrameLifetime: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let wrappers: [CVMetalTexture]

    init(pixelBuffer: CVPixelBuffer, wrappers: [CVMetalTexture]) {
        self.pixelBuffer = pixelBuffer
        self.wrappers = wrappers
    }
}

nonisolated private final class MaskReadback: @unchecked Sendable {
    let captured: MTLTexture?
    let comparison: MTLBuffer?
    let generation: UInt64

    init(captured: MTLTexture?, comparison: MTLBuffer?, generation: UInt64) {
        self.captured = captured
        self.comparison = comparison
        self.generation = generation
    }
}

/// One waiting capture frame, at most one GPU render. All Metal work stays off
/// the capture callback's queue.
nonisolated final class MetalPreviewRenderer: @unchecked Sendable {
    let layer: CAMetalLayer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let yuvPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    private let capturePipeline: MTLComputePipelineState
    private let comparePipeline: MTLComputePipelineState
    private let renderQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.render", qos: .userInitiated)
    private let slotLock = NSLock()
    private var waitingFrame: CVPixelBuffer?
    private var renderActive = false
    private var pendingCapture: CGRect?
    private var maskTexture: MTLTexture?
    private var maskRegion: CGRect?
    private var similarityThreshold: Float = 0.9
    private var maskGeneration: UInt64 = 0
    var onMaskCaptured: (@Sendable (NSImage?) -> Void)?
    var onMaskCaptureFailed: (@Sendable () -> Void)?
    var onSimilarity: (@Sendable (Bool?) -> Void)?

    init(device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else { throw PreviewError.commandQueue }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { throw PreviewError.textureCache }

        let shader = """
        #include <metal_stdlib>
        using namespace metal;
        struct VertexOut { float4 position [[position]]; float2 uv; };
        vertex VertexOut previewVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            constexpr float2 corners[6] = {
                {-1, -1}, {1, -1}, {-1, 1}, {1, -1}, {1, 1}, {-1, 1}
            };
            float2 p = corners[id];
            return {float4(p * scale, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5)};
        }
        fragment float4 previewYUV(VertexOut in [[stage_in]],
                                   texture2d<float> yPlane [[texture(0)]],
                                   texture2d<float> uvPlane [[texture(1)]],
                                   constant uint2 &options [[buffer(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            float y = yPlane.sample(s, in.uv).r;
            float2 uv = uvPlane.sample(s, in.uv).rg - 0.5;
            if (options.x == 0) { y = (y - 16.0 / 255.0) * (255.0 / 219.0);
                                  uv *= 255.0 / 224.0; }
            float3 rgb;
            if (options.y != 0) {
                rgb = float3(y + 1.4020 * uv.y,
                             y - 0.3441 * uv.x - 0.7141 * uv.y,
                             y + 1.7720 * uv.x);
            } else {
                rgb = float3(y + 1.5748 * uv.y,
                             y - 0.1873 * uv.x - 0.4681 * uv.y,
                             y + 1.8556 * uv.x);
            }
            return float4(rgb, 1);
        }
        fragment float4 previewBGRA(VertexOut in [[stage_in]],
                                    texture2d<float> frame [[texture(0)]]) {
            constexpr sampler s(mag_filter::linear, min_filter::linear);
            return frame.sample(s, in.uv);
        }
        kernel void captureMask(texture2d<float, access::sample> frame [[texture(0)]],
                                texture2d<float, access::write> mask [[texture(1)]],
                                constant float4 &region [[buffer(0)]],
                                uint2 id [[thread_position_in_grid]]) {
            if (id.x >= mask.get_width() || id.y >= mask.get_height()) return;
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float2 uv = (region.xy + (float2(id) + 0.5) * region.zw /
                         float2(mask.get_width(), mask.get_height())) /
                        float2(frame.get_width(), frame.get_height());
            mask.write(frame.sample(s, uv), id);
        }
        kernel void compareMask(texture2d<float, access::sample> frame [[texture(0)]],
                                texture2d<float, access::sample> mask [[texture(1)]],
                                device atomic_uint *difference [[buffer(0)]],
                                constant float4 &region [[buffer(1)]],
                                uint id [[thread_position_in_grid]]) {
            if (id >= 36864) return;
            constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
            float2 uv = (float2(id % 256, id / 256) + 0.5) / float2(256, 144);
            float2 frameUV = (region.xy + uv * region.zw) /
                             float2(frame.get_width(), frame.get_height());
            float3 a = frame.sample(s, frameUV).rgb;
            float3 b = mask.sample(s, uv).rgb;
            uint delta = uint(round(abs(a.r-b.r)*255.0)) +
                         uint(round(abs(a.g-b.g)*255.0)) +
                         uint(round(abs(a.b-b.b)*255.0));
            atomic_fetch_add_explicit(difference, delta, memory_order_relaxed);
        }
        """
        let library = try device.makeLibrary(source: shader, options: nil)
        func pipeline(_ fragment: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        let yuvPipeline = try pipeline("previewYUV")
        let bgraPipeline = try pipeline("previewBGRA")
        let capturePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "captureMask")!)
        let comparePipeline = try device.makeComputePipelineState(function: library.makeFunction(name: "compareMask")!)
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)

        self.device = device
        self.layer = layer
        self.commandQueue = commandQueue
        self.textureCache = cache
        self.yuvPipeline = yuvPipeline
        self.bgraPipeline = bgraPipeline
        self.capturePipeline = capturePipeline
        self.comparePipeline = comparePipeline
    }

    /// UI requests are serialized with rendering; no GPU work runs on the main thread.
    func captureMask(in region: CGRect) {
        renderQueue.async { [self] in
            maskGeneration &+= 1
            pendingCapture = region
        }
    }

    func removeMask() {
        renderQueue.async { [self] in
            maskGeneration &+= 1
            pendingCapture = nil
            maskTexture = nil
            maskRegion = nil
            onMaskCaptured?(nil)
            onSimilarity?(nil)
        }
    }

    func setSimilarityThreshold(_ value: Double) {
        renderQueue.async { [self] in similarityThreshold = Float(min(1, max(0, value))) }
    }

    /// Called on the capture delegate queue. Replacing a waiting frame releases
    /// the old one immediately; the frame being rendered is retained separately.
    func offer(_ frame: CVPixelBuffer) {
        slotLock.lock()
        waitingFrame = frame
        let shouldStart = !renderActive
        if shouldStart { renderActive = true }
        slotLock.unlock()
        if shouldStart { renderQueue.async { [self] in renderLatest() } }
    }

    private func renderLatest() {
        slotLock.lock()
        let frame = waitingFrame
        waitingFrame = nil
        if frame == nil { renderActive = false }
        slotLock.unlock()
        guard let frame else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let drawable = layer.nextDrawable() else {
            retryLatest()
            return
        }

        let pixelFormat = CVPixelBufferGetPixelFormatType(frame)
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        var wrappers: [CVMetalTexture] = []
        var textures: [MTLTexture] = []
        if pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
           pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange {
            guard let y = texture(frame, format: .r8Unorm, plane: 0),
                  let uv = texture(frame, format: .rg8Unorm, plane: 1),
                  let yTexture = CVMetalTextureGetTexture(y),
                  let uvTexture = CVMetalTextureGetTexture(uv) else {
                retryLatest()
                return
            }
            wrappers = [y, uv]
            textures = [yTexture, uvTexture]
        } else if pixelFormat == kCVPixelFormatType_32BGRA,
                  let bgra = texture(frame, format: .bgra8Unorm, plane: 0),
                  let bgraTexture = CVMetalTextureGetTexture(bgra) {
            wrappers = [bgra]
            textures = [bgraTexture]
        } else {
            retryLatest()
            return
        }

        let target = drawable.texture
        let sourceAspect = Float(width) / Float(height)
        let targetAspect = Float(target.width) / Float(target.height)
        var scale = sourceAspect > targetAspect
            ? SIMD2<Float>(1, targetAspect / sourceAspect)
            : SIMD2<Float>(sourceAspect / targetAspect, 1)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            retryLatest()
            return
        }
        let isYUV = textures.count == 2
        encoder.setRenderPipelineState(isYUV ? yuvPipeline : bgraPipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        for (index, texture) in textures.enumerated() {
            encoder.setFragmentTexture(texture, index: index)
        }
        if isYUV {
            let fullRange = pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            var options = SIMD2<UInt32>(fullRange ? 1 : 0, width < 1280 ? 1 : 0)
            encoder.setFragmentBytes(&options, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        let capture = pendingCapture
        pendingCapture = nil
        var capturedTexture: MTLTexture?
        if let capture {
            let region = drawableRegion(capture, target: target, scale: scale)
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: max(1, Int(region.z.rounded())),
                height: max(1, Int(region.w.rounded())),
                mipmapped: false
            )
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            if let newMask = device.makeTexture(descriptor: descriptor),
               encodeCapture(frame: target, mask: newMask, region: region, in: commandBuffer) {
                capturedTexture = newMask
            } else {
                onMaskCaptureFailed?()
            }
        }
        var comparison: MTLBuffer?
        if let comparisonMask = capturedTexture ?? maskTexture,
           let comparisonRegion = capturedTexture == nil ? maskRegion : capture {
            comparison = encodeComparison(frame: target, mask: comparisonMask,
                                          region: drawableRegion(comparisonRegion, target: target, scale: scale),
                                          in: commandBuffer)
        }
        let threshold = similarityThreshold
        let readback = MaskReadback(captured: capturedTexture, comparison: comparison,
                                    generation: maskGeneration)
        let lifetime = FrameLifetime(pixelBuffer: frame, wrappers: wrappers)
        commandBuffer.addCompletedHandler { [self, lifetime, readback] command in
            // Keep the Core Video image and wrappers alive until the GPU is done.
            withExtendedLifetime(lifetime) {}
            renderQueue.async { [self] in
                if command.status == .completed && readback.generation == maskGeneration {
                    if let capturedTexture = readback.captured {
                        if let image = maskImage(from: capturedTexture) {
                            maskTexture = capturedTexture
                            maskRegion = capture
                            onMaskCaptured?(image)
                        } else {
                            onMaskCaptureFailed?()
                        }
                    }
                    if let comparison = readback.comparison {
                        let difference = comparison.contents().load(as: UInt32.self)
                        let similarity = 1 - Float(difference) / Float(36864 * 3 * 255)
                        onSimilarity?(similarity >= threshold)
                    }
                } else if command.status != .completed && readback.captured != nil {
                    onMaskCaptureFailed?()
                }
                renderLatest()
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func retryLatest() {
        renderQueue.async { [self] in renderLatest() }
    }

    private func encodeCapture(frame: MTLTexture, mask: MTLTexture,
                               region: SIMD4<Float>, in command: MTLCommandBuffer) -> Bool {
        guard let compute = command.makeComputeCommandEncoder() else { return false }
        var parameters = region
        compute.setComputePipelineState(capturePipeline)
        compute.setTexture(frame, index: 0)
        compute.setTexture(mask, index: 1)
        compute.setBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        compute.dispatchThreads(MTLSize(width: mask.width, height: mask.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        return true
    }

    private func encodeComparison(frame: MTLTexture, mask: MTLTexture,
                                  region: SIMD4<Float>, in command: MTLCommandBuffer) -> MTLBuffer? {
        guard let result = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared),
              let compute = command.makeComputeCommandEncoder() else { return nil }
        result.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        var parameters = region
        compute.setComputePipelineState(comparePipeline)
        compute.setTexture(frame, index: 0)
        compute.setTexture(mask, index: 1)
        compute.setBuffer(result, offset: 0, index: 0)
        compute.setBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        compute.dispatchThreads(MTLSize(width: 36864, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: min(256, comparePipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        compute.endEncoding()
        return result
    }

    /// Offscreen entry points exercise the same kernels as the live preview without a window.
    func wholeFrameMask(from frame: CVPixelBuffer) -> MTLTexture? {
        mask(from: frame, region: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func mask(from frame: CVPixelBuffer, region: CGRect) -> MTLTexture? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              validNormalizedRegion(region),
              let source = texture(frame, format: .bgra8Unorm, plane: 0),
              let sourceTexture = CVMetalTextureGetTexture(source),
              let command = commandQueue.makeCommandBuffer() else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(1, Int((region.width * CGFloat(sourceTexture.width)).rounded())),
            height: max(1, Int((region.height * CGFloat(sourceTexture.height)).rounded())),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let mask = device.makeTexture(descriptor: descriptor),
              encodeCapture(frame: sourceTexture, mask: mask,
                            region: textureRegion(region, width: sourceTexture.width,
                                                  height: sourceTexture.height),
                            in: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        return command.status == .completed ? mask : nil
    }

    func isWholeFrameSimilar(_ frame: CVPixelBuffer, to mask: MTLTexture,
                             threshold: Double = 0.9) -> Bool? {
        isRegionSimilar(frame, to: mask,
                        region: CGRect(x: 0, y: 0, width: 1, height: 1), threshold: threshold)
    }

    func isRegionSimilar(_ frame: CVPixelBuffer, to mask: MTLTexture,
                         region: CGRect, threshold: Double = 0.9) -> Bool? {
        guard CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA,
              validNormalizedRegion(region),
              let source = texture(frame, format: .bgra8Unorm, plane: 0),
              let sourceTexture = CVMetalTextureGetTexture(source),
              let command = commandQueue.makeCommandBuffer(),
              let result = encodeComparison(frame: sourceTexture, mask: mask,
                                            region: textureRegion(region, width: sourceTexture.width,
                                                                  height: sourceTexture.height),
                                            in: command) else { return nil }
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }
        let difference = result.contents().load(as: UInt32.self)
        return 1 - Double(difference) / Double(36864 * 3 * 255) >= threshold
    }

    private func validNormalizedRegion(_ region: CGRect) -> Bool {
        region.minX >= 0 && region.minY >= 0 && region.maxX <= 1 && region.maxY <= 1 &&
            region.width > 0 && region.height > 0
    }

    private func textureRegion(_ region: CGRect, width: Int, height: Int) -> SIMD4<Float> {
        SIMD4<Float>(Float(region.minX) * Float(width), Float(region.minY) * Float(height),
                     Float(region.width) * Float(width), Float(region.height) * Float(height))
    }

    private func drawableRegion(_ selection: CGRect, target: MTLTexture,
                                scale: SIMD2<Float>) -> SIMD4<Float> {
        let width = Float(target.width), height = Float(target.height)
        return SIMD4<Float>(
            (1 - scale.x) * width / 2 + Float(selection.minX) * scale.x * width,
            (1 - scale.y) * height / 2 + Float(selection.minY) * scale.y * height,
            Float(selection.width) * scale.x * width,
            Float(selection.height) * scale.y * height
        )
    }

    private func maskImage(from texture: MTLTexture) -> NSImage? {
        let rowBytes = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * texture.height)
        bytes.withUnsafeMutableBytes { pointer in
            texture.getBytes(pointer.baseAddress!, bytesPerRow: rowBytes,
                             from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: texture.width, height: texture.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: texture.width, height: texture.height))
    }

    func texture(_ frame: CVPixelBuffer, format: MTLPixelFormat, plane: Int) -> CVMetalTexture? {
        let width = CVPixelBufferIsPlanar(frame) ? CVPixelBufferGetWidthOfPlane(frame, plane) : CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferIsPlanar(frame) ? CVPixelBufferGetHeightOfPlane(frame, plane) : CVPixelBufferGetHeight(frame)
        var result: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, frame, nil, format, width, height, plane, &result
        )
        return status == kCVReturnSuccess ? result : nil
    }
}

private enum PreviewError: LocalizedError {
    case commandQueue
    case textureCache

    var errorDescription: String? {
        switch self {
        case .commandQueue: "Metal could not create a preview command queue."
        case .textureCache: "Metal could not map video frames to textures."
        }
    }
}
