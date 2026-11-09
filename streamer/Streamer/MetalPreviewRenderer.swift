import AVFoundation
import Metal
import QuartzCore

nonisolated private final class PendingTexture: @unchecked Sendable {
    let texture: CVMetalTexture

    init(_ texture: CVMetalTexture) { self.texture = texture }
}

/// Converts capture pixel buffers to Metal textures and draws them into the preview layer.
nonisolated final class MetalPreviewRenderer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let layer: CAMetalLayer
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache

    init(device: MTLDevice) throws {
        guard let commandQueue = device.makeCommandQueue() else { throw CaptureFailure.metalUnavailable }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        vertex VertexOut previewVertex(uint id [[vertex_id]], constant float2 &scale [[buffer(0)]]) {
            constexpr float2 positions[6] = {
                {-1.0, -1.0}, {1.0, -1.0}, {-1.0, 1.0},
                {1.0, -1.0}, {1.0, 1.0}, {-1.0, 1.0}
            };
            float2 p = positions[id];
            VertexOut out;
            out.position = float4(p * scale, 0.0, 1.0);
            out.uv = float2((p.x + 1.0) * 0.5, (1.0 - p.y) * 0.5);
            return out;
        }

        fragment float4 previewFragment(VertexOut in [[stage_in]],
                                        texture2d<float> video [[texture(0)]]) {
            constexpr sampler sampleFilter(mag_filter::linear, min_filter::linear);
            return video.sample(sampleFilter, in.uv);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "previewVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "previewFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        var textureCache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
        guard status == kCVReturnSuccess, let textureCache else { throw CaptureFailure.metalUnavailable }

        let layer = CAMetalLayer()
        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        self.layer = layer
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = textureCache
        super.init()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            width, height, 0, &cvTexture
        ) == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture),
              let drawable = layer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

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
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&scale, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        // Keep the Core Video wrapper (and its pixel buffer) alive until the GPU has read it.
        let pendingTexture = PendingTexture(cvTexture)
        commandBuffer.addCompletedHandler { _ in _ = pendingTexture.texture }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
