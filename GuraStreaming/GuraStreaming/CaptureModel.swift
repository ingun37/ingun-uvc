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

    init(device: AVCaptureDevice, audioDevice: AVCaptureDevice?, frameRate: Double) throws {
        guard let range = device.activeFormat.videoSupportedFrameRateRanges.first(where: {
            frameRate >= $0.minFrameRate - 0.001 && frameRate <= $0.maxFrameRate + 0.001
        }) else { throw CaptureFailure.unsupportedFrameRate }
        let frameDuration: CMTime
        if abs(frameRate - range.minFrameRate) < 0.01 {
            frameDuration = range.maxFrameDuration
        } else if abs(frameRate - range.maxFrameRate) < 0.01 {
            frameDuration = range.minFrameDuration
        } else {
            frameDuration = CMTime(value: 1_000_000,
                                   timescale: CMTimeScale((frameRate * 1_000_000).rounded()))
        }
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard let metalDevice = MTLCreateSystemDefaultDevice() else { throw CaptureFailure.metalUnavailable }
        let renderer = try MetalPreviewRenderer(device: metalDevice)
        let output = AVCaptureVideoDataOutput()
        let delegate = VideoFrameDelegate(renderer: renderer)
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: frameQueue)

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
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
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
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
        guard CMTimeCompare(device.activeVideoMinFrameDuration, frameDuration) == 0,
              CMTimeCompare(device.activeVideoMaxFrameDuration, frameDuration) == 0 else {
            throw CaptureFailure.frameRateNotRetained
        }

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
    case unsupportedFrameRate
    case frameRateNotRetained
    case metalUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupported: "This device or its video output cannot be added to a capture session."
        case .unsupportedPixelFormat: "This video source has no supported preview pixel format."
        case .unsupportedFrameRate: "This frame rate is no longer supported by the video source."
        case .frameRateNotRetained: "The capture session did not retain the selected frame rate."
        case .metalUnavailable: "Metal is unavailable, so the video preview cannot be displayed."
        }
    }
}

@Observable
final class CaptureModel {
    enum Screen {
        case devices
        case frequency(AVCaptureDevice)
        case detail(AVCaptureDevice, CaptureResource)
    }

    var devices: [AVCaptureDevice] = []
    var screen: Screen = .devices
    var message = ""
    var streamMessage = ""
    var permissionDenied = false
    var audioMessage = ""
    var selectedFrameRate = 0.0
    var preparingCapture = false

    var supportedFrameRates: [Double] {
        guard case let .frequency(device) = screen else { return [] }
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        let commonRates: [Double] = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 100, 120, 144, 240]
        let boundaries = ranges.flatMap { [$0.minFrameRate, $0.maxFrameRate] }
        let candidates = boundaries + commonRates.filter { rate in
            !boundaries.contains(where: { abs($0 - rate) < 0.01 })
        }
        return candidates.filter { rate in
            ranges.contains { rate >= $0.minFrameRate - 0.001 && rate <= $0.maxFrameRate + 0.001 }
        }.sorted().reduce(into: [Double]()) { result, rate in
            if result.last.map({ abs($0 - rate) > 0.01 }) ?? true { result.append(rate) }
        }
    }

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

    func select(_ device: AVCaptureDevice) {
        message = ""
        screen = .frequency(device)
        let currentDuration = device.activeVideoMinFrameDuration.seconds
        let currentRate = currentDuration > 0 ? 1 / currentDuration : 0
        selectedFrameRate = supportedFrameRates.min(by: {
            abs($0 - currentRate) < abs($1 - currentRate)
        }) ?? 0
    }

    func open(_ device: AVCaptureDevice) async {
        guard case let .frequency(currentDevice) = screen,
              currentDevice.uniqueID == device.uniqueID,
              supportedFrameRates.contains(where: { abs($0 - selectedFrameRate) < 0.01 }),
              !preparingCapture else { return }
        let frameRate = selectedFrameRate
        preparingCapture = true
        defer { preparingCapture = false }
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
        guard case let .frequency(currentDevice) = screen,
              currentDevice.uniqueID == device.uniqueID else { return }
        do {
            let resource = try CaptureResource(device: device, audioDevice: authorized ? audioDevice : nil,
                                               frameRate: frameRate)
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
        switch screen {
        case let .detail(device, _): screen = .frequency(device)
        case .frequency: screen = .devices
        case .devices: break
        }
        streamMessage = ""
    }

    func disconnected(_ notification: Notification) {
        let device: AVCaptureDevice
        switch screen {
        case let .frequency(selected): device = selected
        case let .detail(selected, _): device = selected
        case .devices: return
        }
        guard let disconnected = notification.object as? AVCaptureDevice,
              disconnected.uniqueID == device.uniqueID else { return }
        screen = .devices
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
