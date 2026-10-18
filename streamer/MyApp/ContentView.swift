import SwiftUI
import AVFoundation
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var model = CaptureModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            switch model.screen {
            case .devices:
                deviceList
            case let .opening(name):
                ProgressView("Opening \(name)…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case let .detail(device, resource):
                HStack {
                    Button("Back", systemImage: "chevron.left") {
                        model.back()
                        Task { await model.refresh() }
                    }
                    Text(device.localizedName).font(.title2.bold())
                    Spacer()
                    Button("Record", systemImage: "record.circle") { model.record(device, resource: resource) }
                }
                DeviceDetail(device: device, resource: resource)
            case let .record(device, recording):
                RecordView(recording: recording) { model.screen = .detail(device, recording.resource) }
            }
            if !model.streamMessage.isEmpty {
                Label(model.streamMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
        }
        .padding(24)
        .frame(minWidth: 720, minHeight: 580)
        .task { await model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { model.disconnected($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.runtimeErrorNotification)) { model.sessionFailed($0) }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification)) { notification in
            if let (_, resource) = model.screen.capture,
               let session = notification.object as? AVCaptureSession, session === resource.session {
                model.streamMessage = "Capture was interrupted. The preview will resume when the device becomes available."
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureSession.interruptionEndedNotification)) { notification in
            if let (_, resource) = model.screen.capture,
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
                    Text("Choose a capture card or camera to inspect its live video.").foregroundStyle(.secondary)
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
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") { NSWorkspace.shared.open(url) }
                    }
                }
            } else if model.devices.isEmpty {
                ContentUnavailableView("No video sources found", systemImage: "video.slash", description: Text("Connect a USB capture card or camera, then click Refresh."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.devices, id: \.uniqueID) { device in
                            Button { model.open(device) } label: {
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


private struct RecordView: View {
    let recording: MovieRecording
    let returnToPreview: () -> Void
    @State private var saveMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Record").font(.title2.bold())
                Spacer()
                if recording.phase == .failed {
                    Button("Back to preview", action: returnToPreview)
                } else {
                    Button("Done") {
                        if recording.phase == .ready { save() }
                        else { recording.finish() }
                    }
                    .disabled(recording.phase == .starting || recording.phase == .finishing)
                }
            }
            CapturePreview(session: recording.resource.session)
                .frame(width: 400, height: 225)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Live recording preview")
            Text(recording.phase.label).font(.headline)
            Text("Temporary file").foregroundStyle(.secondary)
            Text(recording.url.path).textSelection(.enabled)
            if !recording.message.isEmpty {
                Label(recording.message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if !saveMessage.isEmpty {
                Label(saveMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            Spacer()
        }
        .onDisappear { recording.finish() }
        .onChange(of: recording.phase) { _, phase in
            if phase == .ready && recording.saveRequested { save() }
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        panel.nameFieldStringValue = formatter.string(from: Date()) + ".mov"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let access = destination.startAccessingSecurityScopedResource()
        defer { if access { destination.stopAccessingSecurityScopedResource() } }
        do {
            // Copy first so a failed save leaves the temporary recording available for retry.
            if FileManager.default.fileExists(atPath: destination.path) {
                let staging = recording.url.deletingLastPathComponent().appendingPathComponent("Save.mov")
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.copyItem(at: recording.url, to: staging)
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.copyItem(at: recording.url, to: destination)
            }
            returnToPreview()
        } catch {
            saveMessage = "Could not save the recording: \(error.localizedDescription). The temporary file is available above; click Done to retry."
        }
    }
}

private struct DeviceDetail: View {
    let device: AVCaptureDevice
    let resource: CaptureResource
    private var rows: [DetailRow] {
        let format = device.activeFormat
        let description = format.formatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let rates = format.videoSupportedFrameRateRanges.map { String(format: "%.2f–%.2f fps", $0.minFrameRate, $0.maxFrameRate) }.joined(separator: ", ")
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                CapturePreview(session: resource.session)
                    .frame(width: 400, height: 225)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("Live video preview")
                GroupBox("Video source") { details(rows) }
                GroupBox("USB descriptors") {
                    let usb = USBDetails.rows(for: device)
                    if usb.isEmpty {
                        Text("USB descriptors are unavailable for this source. The device may use a non-USB transport, or macOS may not expose its registry information.")
                            .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(8)
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
                    Text(row.value.isEmpty ? "Not reported" : row.value).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.padding(8)
    }

    private func fourCC(_ value: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xff) }
        if bytes.allSatisfy({ (32...126).contains($0) }) { return String(bytes: bytes, encoding: .ascii) ?? "Unknown" }
        return String(format: "0x%08X", value)
    }
}

private struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.previewLayer.session = session
    }

    static func dismantleNSView(_ view: PreviewView, coordinator: ()) {
        view.previewLayer.session = nil
    }
}

private final class PreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = previewLayer
        previewLayer.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}
