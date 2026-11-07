import CoreGraphics
import Foundation
import Metal
import MetalKit

struct BasketSide {
    private let device: any MTLDevice
    private let pipeline: any MTLComputePipelineState
    private let queue: any MTLCommandQueue
    private let textureLoader: MTKTextureLoader

    init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw DetectionError.metalUnavailable
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "sumBasketSideBrightness"),
              let queue = device.makeCommandQueue() else {
            throw DetectionError.metalUnavailable
        }
        self.device = device
        pipeline = try device.makeComputePipelineState(function: function)
        self.queue = queue
        textureLoader = MTKTextureLoader(device: device)
    }

    func isRight(_ image: CGImage) throws -> Bool {
        let texture = try textureLoader.newTexture(cgImage: image, options: [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue
        ])
        let rowCount = texture.height
        guard let sums = device.makeBuffer(length: rowCount * MemoryLayout<SIMD2<Float>>.stride,
                                           options: .storageModeShared),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw DetectionError.metalUnavailable
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBuffer(sums, offset: 0, index: 0)
        let threadWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        encoder.dispatchThreads(MTLSize(width: rowCount, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? DetectionError.computeFailed }

        let rows = sums.contents().bindMemory(to: SIMD2<Float>.self, capacity: rowCount)
        var left = 0.0
        var right = 0.0
        for row in 0..<rowCount {
            left += Double(rows[row].x)
            right += Double(rows[row].y)
        }
        return right < left
    }

    // Crude normalized half-court quadrilateral supplied for this broadcast view.
    static func project(_ court: CGPoint, right: Bool) -> CGPoint {
        let x = min(max((court.x + 250) / 500, 0), 1)
        let y = min(max((court.y + 50) / 470, 0), 1)
        let leftEdge = 0.6 - 0.9 * y
        let rightEdge = 1.0 - 1.3 * y
        let screenX = leftEdge + (rightEdge - leftEdge) * x
        let screenY = 0.3 + x * (0.7 + 0.3 * y)
        return CGPoint(x: right ? screenX : 1 - screenX, y: screenY)
    }

    enum DetectionError: Error {
        case metalUnavailable, computeFailed
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void sumBasketSideBrightness(texture2d<float, access::read> frame [[texture(0)]],
                                        device float2 *rowSums [[buffer(0)]],
                                        uint row [[thread_position_in_grid]]) {
        if (row >= frame.get_height()) return;
        float2 sums = 0.0;
        const uint midpoint = frame.get_width() / 2;
        for (uint x = 0; x < frame.get_width(); ++x) {
            const float3 rgb = frame.read(uint2(x, row)).rgb;
            const float brightness = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            if (x < midpoint) sums.x += brightness;
            else if (x >= frame.get_width() - midpoint) sums.y += brightness;
        }
        rowSums[row] = sums;
    }
    """
}
