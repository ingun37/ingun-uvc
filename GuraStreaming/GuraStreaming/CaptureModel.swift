import AVFoundation
import Metal
import Observation

/// The capture callback only retains the newest waiting pixel buffer.
final class VideoFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let renderer: MetalPreviewRenderer

    init(renderer: MetalPreviewRenderer) {
        self.renderer = renderer
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        renderer.offer(pixelBuffer)
    }
}

/// Owns the session and its video and optional audio outputs for the detail scene.
final class CaptureResource: @unchecked Sendable {
    let session: AVCaptureSession
    let videoOutput: AVCaptureVideoDataOutput
    let frameDelegate: VideoFrameDelegate
    let renderer: MetalPreviewRenderer
    let audioMeter = AudioLevelMeter()
    let audioSourceName: String?
    private let audioDelegate: AudioLevelDelegate?
    private let sessionQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.session")
    private let frameQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.frames")
    private let audioQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.audioFrames")

    init(device: AVCaptureDevice, audioDevice: AVCaptureDevice?) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard let metalDevice = MTLCreateSystemDefaultDevice() else { throw CaptureFailure.metalUnavailable }
        let renderer = try MetalPreviewRenderer(device: metalDevice)
        let output = AVCaptureVideoDataOutput()
        let delegate = VideoFrameDelegate(renderer: renderer)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: frameQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureFailure.unsupported
        }
        session.addInput(input)
        session.addOutput(output)

        var installedAudioDelegate: AudioLevelDelegate?
        var installedAudioName: String?
        var installedAudioOutput: AVCaptureAudioDataOutput?
        if let audioDevice {
            do {
                let usesVideoInput = audioDevice.uniqueID == device.uniqueID && device.hasMediaType(.audio)
                let audioInput = usesVideoInput ? nil : try AVCaptureDeviceInput(device: audioDevice)
                if let audioInput, session.canAddInput(audioInput) { session.addInput(audioInput) }
                if audioInput == nil || session.inputs.contains(where: { $0 === audioInput }) {
                    let audioOutput = AVCaptureAudioDataOutput()
                    audioOutput.audioSettings = [
                        AVFormatIDKey: kAudioFormatLinearPCM,
                        AVLinearPCMIsFloatKey: true,
                        AVLinearPCMBitDepthKey: 32,
                        AVLinearPCMIsNonInterleaved: false
                    ]
                    if session.canAddOutput(audioOutput) {
                        let processor = AudioLevelProcessor(meter: audioMeter)
                        let delegate = AudioLevelDelegate(processor: processor)
                        audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
                        session.addOutput(audioOutput)
                        installedAudioDelegate = delegate
                        installedAudioName = audioDevice.localizedName
                        installedAudioOutput = audioOutput
                    }
                }
            } catch {
                // Video preview still works if this source's audio cannot open.
            }
        }
        session.commitConfiguration()
        if installedAudioOutput?.connection(with: .audio) == nil {
            installedAudioDelegate = nil
            installedAudioName = nil
        }

        // Prefer native bi-planar capture data. BGRA is a fallback for sources that
        // do not offer either YUV format.
        let formats = output.availableVideoPixelFormatTypes
        let selected = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                        kCVPixelFormatType_32BGRA].first { formats.contains($0) }
        guard let selected else { throw CaptureFailure.unsupportedPixelFormat }
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: selected]

        self.session = session
        self.videoOutput = output
        self.frameDelegate = delegate
        self.renderer = renderer
        self.audioDelegate = installedAudioDelegate
        self.audioSourceName = installedAudioName
    }

    func start() {
        let session = session
        sessionQueue.async { session.startRunning() }
    }

    deinit {
        let session = session
        sessionQueue.async {
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }
}

private enum CaptureFailure: LocalizedError {
    case unsupported
    case unsupportedPixelFormat
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "This device or its video output cannot be added to a capture session."
        case .unsupportedPixelFormat: "This video source has no supported preview pixel format."
        case .metalUnavailable: "Metal is unavailable, so the video preview cannot be displayed."
        }
    }
}

@Observable
final class CaptureModel {
    enum Screen {
        case devices
        case detail(AVCaptureDevice, CaptureResource)
    }

    var devices: [AVCaptureDevice] = []
    var screen: Screen = .devices
    var message = ""
    var streamMessage = ""
    var permissionDenied = false
    var audioMessage = ""

    func refresh() async {
        message = ""
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                permissionDenied = true
                return
            }
        case .authorized:
            break
        default:
            permissionDenied = true
            return
        }
        permissionDenied = false
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    func open(_ device: AVCaptureDevice) async {
        message = ""
        streamMessage = ""
        audioMessage = ""
        let audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .microphone], mediaType: .audio, position: .unspecified
        ).devices
        let audioDevice = device.hasMediaType(.audio) ? device
            : device.linkedDevices.first(where: { $0.hasMediaType(.audio) })
                ?? audioDevices.first(where: { $0.localizedName == device.localizedName })
        let authorized: Bool
        if audioDevice != nil {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: authorized = true
            case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
            default: authorized = false
            }
        } else {
            authorized = false
        }
        do {
            let resource = try CaptureResource(device: device, audioDevice: authorized ? audioDevice : nil)
            screen = .detail(device, resource)
            audioMessage = resource.audioSourceName == nil
                ? (audioDevice == nil ? "No audio source is linked to this video source."
                   : authorized ? "This audio source could not be opened." : "Allow microphone access to show audio levels.")
                : ""
            resource.start()
        } catch {
            message = error.localizedDescription
        }
    }

    func back() {
        screen = .devices
        streamMessage = ""
    }

    func disconnected(_ notification: Notification) {
        guard case let .detail(device, _) = screen,
              let disconnected = notification.object as? AVCaptureDevice,
              disconnected.uniqueID == device.uniqueID else { return }
        back()
        devices.removeAll { $0.uniqueID == device.uniqueID }
        message = "\(device.localizedName) was disconnected. Reconnect it and refresh the list."
    }

    func sessionFailed(_ notification: Notification) {
        guard case let .detail(_, resource) = screen,
              let session = notification.object as? AVCaptureSession,
              session === resource.session else { return }
        streamMessage = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "The capture session stopped unexpectedly. Go back and reopen the device to retry."
    }
}
