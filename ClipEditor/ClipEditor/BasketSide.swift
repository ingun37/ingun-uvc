import CoreGraphics
import Foundation

enum BasketSide {
    static func isRight(_ image: CGImage) -> Bool {
        let width = 160, height = 90
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var scores = [Double](repeating: 0, count: 2)
        for y in stride(from: height / 4 + 4, to: 3 * height / 4 - 4, by: 2) {
            for x in stride(from: 4, to: width - 4, by: 2) {
                var sum = 0.0, squares = 0.0
                for dy in -4...4 {
                    for dx in -4...4 {
                        let value = Double(pixels[(y + dy) * width + x + dx])
                        sum += value; squares += value * value
                    }
                }
                scores[x < width / 2 ? 0 : 1] += squares / 81 - pow(sum / 81, 2)
            }
        }
        return scores[1] > scores[0]
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
}
