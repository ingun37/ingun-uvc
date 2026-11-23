import AVFoundation
import CoreVideo
import SwiftUI
import Vision

struct ShotEffectWindow: Codable, Hashable {
    let clipID: UUID
    let attemptIndex: Int
    let videoURL: URL
    let clipStart: Double
    let attemptTime: Double
    let playerID: String?
    let playerName: String
    let shotDescription: String
    let shotX: Double?
    let shotY: Double?
    let settings: ShotEffectSettings
}

struct ShotEffectView: View {
    @Environment(ShotEffectStore.self) private var shotEffects
    let selection: ShotEffectWindow
    @State private var time: Double
    @State private var frame: CGImage?
    @State private var displayedTime: Double?
    @State private var maskOverlay: CGImage?
    @State private var maskBounds: CGRect?
    @State private var maskPNG: Data?
    @State private var maskPixels: Data?
    @State private var message: String?
    @State private var isFindingPerson = false
    @State private var maskRequestID = UUID()

    init(selection: ShotEffectWindow) {
        self.selection = selection
        _time = State(initialValue: max(selection.clipStart, selection.attemptTime - 0.7))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose the release frame and click the shooter.")
                .font(.headline)
            GeometryReader { geometry in
                if let frame {
                    let scale = min(geometry.size.width / CGFloat(frame.width),
                                    geometry.size.height / CGFloat(frame.height))
                    let size = CGSize(width: CGFloat(frame.width) * scale,
                                      height: CGFloat(frame.height) * scale)
                    ZStack {
                        Image(decorative: frame, scale: 1)
                            .resizable()
                        if let maskOverlay {
                            Image(decorative: maskOverlay, scale: 1)
                                .resizable()
                                .allowsHitTesting(false)
                        }
                        if let maskBounds {
                            let area = ShotEffectArea.ellipse(
                                atBottomOf: maskBounds,
                                in: CGSize(width: frame.width, height: frame.height),
                                settings: selection.settings)
                            Ellipse()
                                .fill(ColorTheme.fontColor2.opacity(0.22))
                                .overlay(Ellipse().strokeBorder(ColorTheme.fontColor2, lineWidth: 2))
                                .frame(width: area.width * scale, height: area.height * scale)
                                .position(x: area.midX * scale, y: area.midY * scale)
                                .allowsHitTesting(false)
                            Rectangle()
                                .strokeBorder(.yellow, lineWidth: 3)
                                .frame(width: maskBounds.width * scale,
                                       height: maskBounds.height * scale)
                                .position(x: maskBounds.midX * scale,
                                          y: maskBounds.midY * scale)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { tap in
                        guard displayedTime == time else { return }
                        let point = CGPoint(x: tap.location.x / size.width * CGFloat(frame.width),
                                            y: tap.location.y / size.height * CGFloat(frame.height))
                        findPerson(in: frame, at: point)
                    })
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                } else {
                    ProgressView("Loading frame…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minHeight: 360)
            .background(.black)
            HStack {
                Text(ClipPlanner.clockLabel(selection.clipStart))
                if selection.attemptTime > selection.clipStart {
                    Slider(value: $time, in: selection.clipStart...selection.attemptTime)
                } else {
                    Slider(value: .constant(selection.clipStart), in: selection.clipStart...(selection.clipStart + 0.001))
                        .disabled(true)
                }
                Text(ClipPlanner.clockLabel(selection.attemptTime))
            }
            .monospacedDigit()
            Text("Frame: \(time, specifier: "%.3f") s · \(max(0, selection.attemptTime - time), specifier: "%.3f") s before attempt")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let frame, let maskBounds {
                VStack(spacing: 8) {
                    HStack {
                        Text("Box width").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(self.maskBounds?.width ?? maskBounds.width) },
                            set: { resizeBox(width: CGFloat($0), in: frame) }),
                            in: 1...Double(frame.width))
                        Text("\(Int(maskBounds.width)) px")
                            .monospacedDigit()
                            .frame(width: 75, alignment: .trailing)
                    }
                    HStack {
                        Text("Box height").frame(width: 80, alignment: .leading)
                        Slider(value: Binding(
                            get: { Double(self.maskBounds?.height ?? maskBounds.height) },
                            set: { resizeBox(height: CGFloat($0), in: frame) }),
                            in: 1...Double(frame.height))
                        Text("\(Int(maskBounds.height)) px")
                            .monospacedDigit()
                            .frame(width: 75, alignment: .trailing)
                    }
                }
            }
            if isFindingPerson {
                ProgressView("Finding player…")
            }
            if let message {
                Text(message).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Apply") {
                    guard let maskBounds, let maskPNG, let maskPixels, let frame else { return }
                    let key = ShotEffectKey(clipID: selection.clipID, attemptIndex: selection.attemptIndex)
                    let location = (selection.shotX != nil && selection.shotY != nil)
                        ? CGPoint(x: selection.shotX!, y: selection.shotY!) : nil
                    shotEffects.effects[key] = AppliedShotEffect(
                        timestamp: time, bounds: maskBounds,
                        frameSize: CGSize(width: frame.width, height: frame.height),
                        maskPNG: maskPNG, maskPixels: maskPixels, playerID: selection.playerID,
                        playerName: selection.playerName,
                        shotDescription: selection.shotDescription,
                        shotLocation: location)
                    message = "Effect saved for this attempt."
                }
                .disabled(maskBounds == nil || maskPNG == nil || maskPixels == nil || displayedTime != time || isFindingPerson)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 580)
        .task(id: time) {
            maskRequestID = UUID()
            isFindingPerson = false
            maskOverlay = nil
            maskBounds = nil
            maskPNG = nil
            maskPixels = nil
            message = nil
            do {
                let url = selection.videoURL
                let requestedTime = time
                let image = try await Task.detached(priority: .userInitiated) {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                    generator.appliesPreferredTrackTransform = true
                    generator.requestedTimeToleranceBefore = .zero
                    generator.requestedTimeToleranceAfter = .zero
                    return try generator.copyCGImage(at: CMTime(seconds: requestedTime, preferredTimescale: 60000),
                                                     actualTime: nil)
                }.value
                guard !Task.isCancelled else { return }
                frame = image
                displayedTime = requestedTime
            } catch {
                guard !Task.isCancelled else { return }
                message = "Could not load this frame: \(error.localizedDescription)"
            }
        }
    }

    private func findPerson(in frame: CGImage, at point: CGPoint) {
        let requestID = UUID()
        maskRequestID = requestID
        isFindingPerson = true
        maskOverlay = nil
        maskBounds = nil
        maskPNG = nil
        maskPixels = nil
        message = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try PersonMask.overlay(in: frame, at: point)
                }.value
                guard maskRequestID == requestID, self.frame === frame else { return }
                maskOverlay = result.image
                maskBounds = result.bounds
                maskPNG = result.maskPNG
                maskPixels = result.maskPixels
            } catch {
                if maskRequestID == requestID, self.frame === frame {
                    message = error.localizedDescription
                }
            }
            if maskRequestID == requestID { isFindingPerson = false }
        }
    }

    private func resizeBox(width: CGFloat? = nil, height: CGFloat? = nil, in frame: CGImage) {
        guard let maskBounds else { return }
        message = nil
        self.maskBounds = ShotEffectArea.resized(
            maskBounds,
            to: CGSize(width: width ?? maskBounds.width, height: height ?? maskBounds.height),
            in: CGSize(width: frame.width, height: frame.height))
    }
}

private enum PersonMask {
    enum Failure: LocalizedError {
        case noPerson
        case unsupportedMask

        var errorDescription: String? {
            switch self {
            case .noPerson: "No player was detected near the click. Try another frame or click closer to the player."
            case .unsupportedMask: "The player mask could not be displayed."
            }
        }
    }

    nonisolated static func overlay(in frame: CGImage, at point: CGPoint) throws -> (image: CGImage, bounds: CGRect, maskPNG: Data, maskPixels: Data) {
        // Center a half-width, half-height crop on the click, shifting it inside the frame at edges.
        let cropWidth = max(1, frame.width / 2)
        let cropHeight = max(1, frame.height / 2)
        let originX = min(max(0, Int(point.x) - cropWidth / 2), frame.width - cropWidth)
        let originY = min(max(0, Int(point.y) - cropHeight / 2), frame.height - cropHeight)
        let rect = CGRect(x: originX, y: originY, width: cropWidth, height: cropHeight)
        guard let crop = frame.cropping(to: rect) else { throw Failure.noPerson }

        let handler = VNImageRequestHandler(cgImage: crop)
        let request = VNGeneratePersonInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw Failure.noPerson
        }

        let labels = observation.instanceMask
        guard CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8 else {
            throw Failure.unsupportedMask
        }
        CVPixelBufferLockBaseAddress(labels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(labels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(labels) else { throw Failure.unsupportedMask }
        let labelWidth = CVPixelBufferGetWidth(labels)
        let labelHeight = CVPixelBufferGetHeight(labels)
        let stride = CVPixelBufferGetBytesPerRow(labels)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let targetX = (point.x - CGFloat(originX)) / CGFloat(cropWidth) * CGFloat(labelWidth)
        let targetY = (point.y - CGFloat(originY)) / CGFloat(cropHeight) * CGFloat(labelHeight)
        var nearest: (label: Int, distance: CGFloat)?
        for y in 0..<labelHeight {
            for x in 0..<labelWidth {
                let label = Int(pixels[y * stride + x])
                guard observation.allInstances.contains(label) else { continue }
                let dx = (CGFloat(x) - targetX) / CGFloat(labelWidth)
                let dy = (CGFloat(y) - targetY) / CGFloat(labelHeight)
                let distance = dx * dx + dy * dy
                if nearest == nil || distance < nearest!.distance {
                    nearest = (label, distance)
                }
            }
        }
        // Avoid selecting a distant bystander when the clicked area has no detected person.
        guard let nearest, nearest.distance < 0.12 * 0.12 else { throw Failure.noPerson }
        let selected = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: nearest.label),
                                                                  from: handler)
        let format = CVPixelBufferGetPixelFormatType(selected)
        guard format == kCVPixelFormatType_OneComponent32Float || format == kCVPixelFormatType_OneComponent8 else {
            throw Failure.unsupportedMask
        }
        CVPixelBufferLockBaseAddress(selected, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(selected, .readOnly) }
        guard let maskBase = CVPixelBufferGetBaseAddress(selected) else { throw Failure.unsupportedMask }
        let maskWidth = CVPixelBufferGetWidth(selected)
        let maskHeight = CVPixelBufferGetHeight(selected)
        let maskStride = CVPixelBufferGetBytesPerRow(selected)
        var rgba = Data(count: frame.width * frame.height * 4)
        var grayscale = Data(count: frame.width * frame.height)
        var minimumX = frame.width
        var minimumY = frame.height
        var maximumX = -1
        var maximumY = -1
        grayscale.withUnsafeMutableBytes { maskDestination in
          rgba.withUnsafeMutableBytes { destination in
            guard let bytes = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            guard let maskBytes = maskDestination.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<cropHeight {
                let maskY = min(maskHeight - 1, y * maskHeight / cropHeight)
                for x in 0..<cropWidth {
                    let maskX = min(maskWidth - 1, x * maskWidth / cropWidth)
                    let alpha: Float
                    if format == kCVPixelFormatType_OneComponent32Float {
                        alpha = maskBase.advanced(by: maskY * maskStride)
                            .assumingMemoryBound(to: Float.self)[maskX]
                    } else {
                        alpha = Float(maskBase.advanced(by: maskY * maskStride)
                            .assumingMemoryBound(to: UInt8.self)[maskX]) / 255
                    }
                    if alpha >= 0.5 {
                        minimumX = min(minimumX, originX + x)
                        minimumY = min(minimumY, originY + y)
                        maximumX = max(maximumX, originX + x)
                        maximumY = max(maximumY, originY + y)
                    }
                    let offset = ((originY + y) * frame.width + originX + x) * 4
                    maskBytes[(originY + y) * frame.width + originX + x] = UInt8(max(0, min(1, alpha)) * 255)
                    bytes[offset] = 0
                    bytes[offset + 1] = 220
                    bytes[offset + 2] = 255
                    bytes[offset + 3] = UInt8(max(0, min(1, alpha)) * 150)
                }
            }
          }
        }
        guard let provider = CGDataProvider(data: rgba as CFData),
              maximumX >= minimumX, maximumY >= minimumY,
              let image = CGImage(width: frame.width, height: frame.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent) else { throw Failure.unsupportedMask }
        let bounds = CGRect(x: minimumX, y: minimumY,
                            width: maximumX - minimumX + 1,
                            height: maximumY - minimumY + 1)
        guard let maskProvider = CGDataProvider(data: grayscale as CFData),
              let maskImage = CGImage(width: frame.width, height: frame.height,
                                      bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: frame.width,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(),
                                      provider: maskProvider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent),
              let png = NSBitmapImageRep(cgImage: maskImage).representation(using: .png, properties: [:]) else {
            throw Failure.unsupportedMask
        }
        return (image, bounds, png, grayscale)
    }
}
