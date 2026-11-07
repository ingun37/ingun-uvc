import AppKit
import AVFoundation
import SwiftUI

enum VideoRegionGeometry {
    static func visionRegion(displaySelection: CGRect, naturalSize: CGSize,
                             preferredTransform: CGAffineTransform) -> CGRect {
        let rawBounds = CGRect(origin: .zero, size: naturalSize)
        let displayBounds = rawBounds.applying(preferredTransform)
        let displayed = CGRect(x: displayBounds.minX + displaySelection.minX * displayBounds.width,
                               y: displayBounds.minY + displaySelection.minY * displayBounds.height,
                               width: displaySelection.width * displayBounds.width,
                               height: displaySelection.height * displayBounds.height)
        let raw = displayed.applying(preferredTransform.inverted())
        let x0 = min(max(raw.minX / naturalSize.width, 0), 1)
        let x1 = min(max(raw.maxX / naturalSize.width, 0), 1)
        let y0 = min(max(raw.minY / naturalSize.height, 0), 1)
        let y1 = min(max(raw.maxY / naturalSize.height, 0), 1)
        return CGRect(x: x0, y: 1 - y1, width: x1 - x0, height: y1 - y0)
    }
}

/// Displays the same player used by the transport controls and edits one normalized rectangle.
struct VideoRegionView: NSViewRepresentable {
    let player: AVPlayer
    @Binding var selection: CGRect?

    func makeNSView(context: Context) -> RegionView {
        let view = RegionView()
        view.playerLayer.player = player
        view.onSelectionChange = { context.coordinator.selection.wrappedValue = $0 }
        return view
    }

    func updateNSView(_ view: RegionView, context: Context) {
        context.coordinator.selection = $selection
        view.playerLayer.player = player
        view.selection = selection
        view.onSelectionChange = { context.coordinator.selection.wrappedValue = $0 }
    }

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    final class Coordinator {
        var selection: Binding<CGRect?>
        init(selection: Binding<CGRect?>) { self.selection = selection }
    }
}

final class RegionView: NSView {
    let playerLayer = AVPlayerLayer()
    private let outlineLayer = CAShapeLayer()
    var selection: CGRect? { didSet { updateOutline() } }
    var onSelectionChange: ((CGRect?) -> Void)?
    private var dragStart: CGPoint?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        layer?.addSublayer(playerLayer)
        outlineLayer.fillColor = NSColor.systemYellow.withAlphaComponent(0.16).cgColor
        outlineLayer.strokeColor = NSColor.systemYellow.cgColor
        outlineLayer.lineWidth = 2
        layer?.addSublayer(outlineLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        playerLayer.frame = bounds
        outlineLayer.frame = bounds
        updateOutline()
    }

    private var videoRect: CGRect {
        let rect = playerLayer.videoRect
        return CGRect(x: rect.minX, y: bounds.height - rect.maxY,
                      width: rect.width, height: rect.height)
    }

    private func updateOutline() {
        guard let selection, playerLayer.videoRect.width > 0,
              playerLayer.videoRect.height > 0 else {
            outlineLayer.path = nil
            return
        }
        let video = playerLayer.videoRect
        let rect = CGRect(x: video.minX + selection.minX * video.width,
                          y: video.minY + (1 - selection.maxY) * video.height,
                          width: selection.width * video.width,
                          height: selection.height * video.height)
        outlineLayer.path = CGPath(rect: rect, transform: nil)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard videoRect.contains(point) else { return }
        dragStart = clamped(point)
        selection = nil
        onSelectionChange?(nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStart else { return }
        let end = clamped(convert(event.locationInWindow, from: nil))
        let rect = CGRect(x: min(dragStart.x, end.x), y: min(dragStart.y, end.y),
                          width: abs(end.x - dragStart.x), height: abs(end.y - dragStart.y))
        selection = normalized(rect)
        onSelectionChange?(selection)
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragStart else { return }
        let end = clamped(convert(event.locationInWindow, from: nil))
        let rect = CGRect(x: min(dragStart.x, end.x), y: min(dragStart.y, end.y),
                          width: abs(end.x - dragStart.x), height: abs(end.y - dragStart.y))
        selection = rect.width >= 4 && rect.height >= 4 ? normalized(rect) : nil
        onSelectionChange?(selection)
        self.dragStart = nil
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, videoRect.minX), videoRect.maxX),
                y: min(max(point.y, videoRect.minY), videoRect.maxY))
    }

    private func normalized(_ rect: CGRect) -> CGRect {
        CGRect(x: (rect.minX - videoRect.minX) / videoRect.width,
               y: (rect.minY - videoRect.minY) / videoRect.height,
               width: rect.width / videoRect.width,
               height: rect.height / videoRect.height)
    }
}
