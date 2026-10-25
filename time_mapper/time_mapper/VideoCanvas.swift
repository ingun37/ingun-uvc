import AVFoundation
import AppKit
import SwiftUI

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> SurfaceView {
        let view = SurfaceView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: SurfaceView, context: Context) {
        view.playerLayer.player = player
    }

    final class SurfaceView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

struct VideoCanvas: View {
    @Bindable var session: VideoSession
    @GestureState private var isDrawing = false

    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / session.videoSize.width,
                            geometry.size.height / session.videoSize.height)
            let displaySize = CGSize(width: session.videoSize.width * scale,
                                     height: session.videoSize.height * scale)
            ZStack {
                Color.black
                ZStack(alignment: .topLeading) {
                    PlayerSurface(player: session.player)
                        .allowsHitTesting(false)
                    if let region = session.region {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.18))
                            .overlay(Rectangle().strokeBorder(.white, lineWidth: 2))
                            .frame(width: region.rect.width * scale, height: region.rect.height * scale)
                            .offset(x: region.rect.minX * scale, y: region.rect.minY * scale)
                            .allowsHitTesting(false)
                    }
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1)
                            .updating($isDrawing) { _, state, _ in state = true }
                            .onChanged { value in
                                session.region = region(from: value.startLocation, to: value.location,
                                                        scale: scale)
                            })
                        .accessibilityLabel("Video selection area")
                        .accessibilityHint("Drag to select a rectangular region of the video.")
                }
                .frame(width: displaySize.width, height: displaySize.height)
            }
            .overlay(alignment: .topLeading) {
                if let region = session.region {
                    RegionInformation(region: region)
                        .padding(10)
                        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: isDrawing) { _, drawing in
                if !drawing, session.region?.isValid == false { session.region = nil }
            }
        }
    }

    private func region(from start: CGPoint, to end: CGPoint, scale: CGFloat) -> VideoRegion {
        func pixelPoint(_ point: CGPoint) -> CGPoint {
            CGPoint(x: min(max(point.x / scale, 0), session.videoSize.width),
                    y: min(max(point.y / scale, 0), session.videoSize.height))
        }
        let a = pixelPoint(start)
        let b = pixelPoint(end)
        return VideoRegion(rect: CGRect(x: min(a.x, b.x), y: min(a.y, b.y),
                                        width: abs(a.x - b.x), height: abs(a.y - b.y)))
    }
}

struct RegionInformation: View {
    let region: VideoRegion

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Selected region").font(.headline)
            Text("Start: (\(number(region.rect.minX)), \(number(region.rect.minY)))")
            Text("End: (\(number(region.rect.maxX)), \(number(region.rect.maxY)))")
            Text("Size: \(number(region.rect.width)) × \(number(region.rect.height)) px")
            Text("Ratio (W/H): \(region.aspectRatio, specifier: "%.3f")")
            Text("Video pixels · top-left origin").font(.caption)
        }
        .monospacedDigit()
    }

    private func number(_ value: CGFloat) -> String { String(format: "%.1f", Double(value)) }
}
