import CoreVideo
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

/// One waiting capture frame, at most one GPU render. All Metal work stays off
/// the capture callback's queue.
nonisolated final class MetalPreviewRenderer: @unchecked Sendable {
    let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let yuvPipeline: MTLRenderPipelineState
    private let bgraPipeline: MTLRenderPipelineState
    private let renderQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.render", qos: .userInitiated)
    private let slotLock = NSLock()
    private var waitingFrame: CVPixelBuffer?
    private var renderActive = false

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
        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)

        self.layer = layer
        self.commandQueue = commandQueue
        self.textureCache = cache
        self.yuvPipeline = yuvPipeline
        self.bgraPipeline = bgraPipeline
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
        let lifetime = FrameLifetime(pixelBuffer: frame, wrappers: wrappers)
        commandBuffer.addCompletedHandler { [self, lifetime] _ in
            // Keep the Core Video image and wrappers alive until the GPU is done.
            withExtendedLifetime(lifetime) {}
            renderQueue.async { [self] in renderLatest() }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func retryLatest() {
        renderQueue.async { [self] in renderLatest() }
    }

    private func texture(_ frame: CVPixelBuffer, format: MTLPixelFormat, plane: Int) -> CVMetalTexture? {
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
