import AVFoundation
import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.screen {
            case .devices:
                deviceList
            case let .frequency(device):
                VStack(alignment: .leading, spacing: 20) {
                    Button("Back to video sources", systemImage: "chevron.left") { model.back() }
                    Text(device.localizedName).font(.largeTitle.bold())
                    Text("Choose a capture frame rate before opening this source.")
                        .foregroundStyle(.secondary)
                    if model.supportedFrameRates.isEmpty {
                        ContentUnavailableView("No frame rates reported", systemImage: "video.slash",
                                               description: Text("This source does not report a supported frame rate for its active format."))
                    } else {
                        Picker("Video frequency", selection: $model.selectedFrameRate) {
                            ForEach(model.supportedFrameRates, id: \.self) { rate in
                                Text(String(format: "%.2f fps", rate)).tag(rate)
                            }
                        }
                        .frame(maxWidth: 360)
                        Button("Open video source", systemImage: "arrow.right") {
                            Task { await model.open(device) }
                        }
                        .disabled(model.preparingCapture)
                    }
                    if !model.message.isEmpty {
                        Label(model.message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            case let .detail(device, resource):
                HStack {
                    Button("Back", systemImage: "chevron.left") {
                        model.back()
                    }
                    .disabled(model.recording?.phase.isBusy == true)
                    Text(device.localizedName).font(.title2.bold())
                    Spacer()
                    Button("Record", systemImage: "record.circle") { model.record(resource) }
                        .disabled(model.recording?.phase.isBusy == true)
                    Button("Stop", systemImage: "stop.circle") { model.recording?.stop() }
                        .disabled(model.recording?.phase != .recording && model.recording?.phase != .starting)
                }
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 16) {
                        CapturePreview(renderer: resource.renderer)
                            .aspectRatio(
                                { let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                                    return CGFloat(size.width) / CGFloat(size.height) }(),
                                contentMode: .fit
                            )
                            .frame(minWidth: 320, maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .accessibilityLabel("Live video preview")
                        AudioVisualizer(meter: resource.audioMeter,
                                        sourceName: resource.audioSourceName,
                                        message: model.audioMessage)
                    }
                    DeviceDetail(device: device)
                        .frame(width: 440)
                }
                if !model.streamMessage.isEmpty {
                    Label(model.streamMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                if let recording = model.recording {
                    Text(recording.message).textSelection(.enabled)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 900, minHeight: 580)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) {
            model.disconnected($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification)) {
            model.sessionFailed($0)
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification)) { notification in
            if case let .detail(_, resource) = model.screen,
               let session = notification.object as? AVCaptureSession, session === resource.session {
                model.streamMessage = "Capture was interrupted. It will resume when the device becomes available."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification)) { notification in
            if case let .detail(_, resource) = model.screen,
               let session = notification.object as? AVCaptureSession, session === resource.session {
                model.streamMessage = ""
            }
        }
    }

    private var deviceList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Video sources").font(.largeTitle.bold())
                    Text("Choose a capture card or camera to inspect its live video.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
            }
            if model.permissionDenied {
                ContentUnavailableView {
                    Label("Camera access required", systemImage: "camera.badge.ellipsis")
                } description: {
                    Text("Allow camera access in System Settings → Privacy & Security → Camera, then refresh.")
                } actions: {
                    Button("Open System Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } else if model.devices.isEmpty {
                ContentUnavailableView("No video sources found", systemImage: "video.slash",
                                       description: Text("Connect a USB capture card or camera, then click Refresh."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.devices, id: \.uniqueID) { device in
                            Button { model.select(device) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "video").font(.title2).frame(width: 36)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.localizedName).font(.headline)
                                        Text(device.deviceType.rawValue).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                }
                                .padding(16).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if !model.message.isEmpty {
                Label(model.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
    }
}

private struct AudioVisualizer: View {
    let meter: AudioLevelMeter
    let sourceName: String?
    let message: String

    var body: some View {
        GroupBox("Audio level") {
            VStack(alignment: .leading, spacing: 8) {
                if let sourceName {
                    Text(sourceName).font(.caption).foregroundStyle(.secondary)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(.green)
                                .frame(width: max(2, geometry.size.width * meter.level))
                        }
                    }
                    .frame(height: 14)
                    .animation(.linear(duration: 0.05), value: meter.level)
                    .accessibilityLabel("Audio level")
                    .accessibilityValue("\(Int(meter.level * 100)) percent")
                } else {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        }
    }
}

private struct CapturePreview: NSViewRepresentable {
    let renderer: MetalPreviewRenderer

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(renderer: renderer)
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.renderer = renderer
    }
}

private final class PreviewView: NSView {
    var renderer: MetalPreviewRenderer {
        didSet {
            if oldValue !== renderer {
                layer = renderer.layer
                needsLayout = true
            }
        }
    }

    init(renderer: MetalPreviewRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer = renderer.layer
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layout() {
        super.layout()
        renderer.layer.contentsScale = window?.backingScaleFactor ?? 1
        renderer.layer.drawableSize = CGSize(
            width: bounds.width * renderer.layer.contentsScale,
            height: bounds.height * renderer.layer.contentsScale
        )
    }
}

private struct DeviceDetail: View {
    let device: AVCaptureDevice

    private var rows: [DetailRow] {
        let format = device.activeFormat
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let rates = format.videoSupportedFrameRateRanges.map {
            String(format: "%.2f–%.2f fps", $0.minFrameRate, $0.maxFrameRate)
        }.joined(separator: ", ")
        return [
            DetailRow(label: "Device type", value: device.deviceType.rawValue),
            DetailRow(label: "Unique ID", value: device.uniqueID),
            DetailRow(label: "Model ID", value: device.modelID),
            DetailRow(label: "Manufacturer", value: device.manufacturer),
            DetailRow(label: "Transport", value: fourCC(UInt32(bitPattern: device.transportType))),
            DetailRow(label: "Media type", value: fourCC(CMFormatDescriptionGetMediaType(description))),
            DetailRow(label: "Pixel format / codec", value: fourCC(CMFormatDescriptionGetMediaSubType(description))),
            DetailRow(label: "Active resolution", value: "\(dimensions.width) × \(dimensions.height)"),
            DetailRow(label: "Supported frame rates", value: rates),
            DetailRow(label: "Available formats", value: "\(device.formats.count)")
        ]
    }

    private var colorRows: [DetailRow] {
        let description = device.activeFormat.formatDescription
        func reported(_ key: CFString) -> String {
            guard let value = CMFormatDescriptionGetExtension(description, extensionKey: key) else {
                return "Not reported"
            }
            return String(describing: value)
        }
        return [
            DetailRow(label: "Color primaries", value: reported(kCMFormatDescriptionExtension_ColorPrimaries)),
            DetailRow(label: "Transfer function", value: reported(kCMFormatDescriptionExtension_TransferFunction)),
            DetailRow(label: "YCbCr matrix", value: reported(kCMFormatDescriptionExtension_YCbCrMatrix))
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox("Video source") { details(rows) }
                GroupBox("Color profile") { details(colorRows) }
                GroupBox("USB descriptors") {
                    let usb = USBDetails.rows(for: device)
                    if usb.isEmpty {
                        Text("USB descriptors are unavailable for this source. The device may use a non-USB transport, or macOS may not expose its registry information.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    } else { details(usb) }
                }
            }
        }
    }

    private func details(_ rows: [DetailRow]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value.isEmpty ? "Not reported" : row.value)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(8)
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        if bytes.allSatisfy({ (32...126).contains($0) }) {
            return String(bytes: bytes, encoding: .ascii) ?? "Unknown"
        }
        return String(format: "0x%08X", value)
    }
}
