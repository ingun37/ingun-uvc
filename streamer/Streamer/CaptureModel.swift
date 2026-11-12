import AVFoundation
import AppKit
import Metal
import Observation

/// Balances the activity token automatically when the preview owner is released.
private final class PreviewActivity {
    private let token: NSObjectProtocol

    init() {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .latencyCritical],
            reason: "Displaying a live video capture preview"
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(token)
    }
}

/// Owns the session for exactly as long as the detail scene needs it.
final class CaptureResource: @unchecked Sendable {
    let session: AVCaptureSession
    let preview: MetalPreviewRenderer
    private let previewActivity: PreviewActivity
    private let queue = DispatchQueue(label: "dev.streamer.capture")

    init(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        guard let metalDevice = MTLCreateSystemDefaultDevice() else { throw CaptureFailure.metalUnavailable }
        let preview = try MetalPreviewRenderer(device: metalDevice)
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(preview, queue: DispatchQueue(label: "dev.streamer.preview.frames"))
        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CaptureFailure.unsupported
        }
        session.addInput(input)
        session.addOutput(videoOutput)
        session.commitConfiguration()
        self.session = session
        self.preview = preview
        previewActivity = PreviewActivity()
    }

    func record(to url: URL, audioDevice: AVCaptureDevice, frameRate: Double, output: AVCaptureMovieFileOutput, delegate: MovieRecording) {
        let session = session
        queue.async {
            guard let videoDevice = (session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
                .first { $0.device.hasMediaType(.video) })?.device else {
                Task { @MainActor in delegate.failed("The video source is no longer available.") }
                return
            }
            session.beginConfiguration()
            // Reuse audio ports on a combined video/audio input when available.
            if !session.inputs.flatMap({ $0.ports }).contains(where: { $0.mediaType == .audio }) {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    guard session.canAddInput(audioInput) else {
                        session.commitConfiguration()
                        Task { @MainActor in delegate.failed("The selected audio source cannot be added to this capture session.") }
                        return
                    }
                    session.addInput(audioInput)
                } catch {
                    session.commitConfiguration()
                    let message = error.localizedDescription
                    Task { @MainActor in delegate.failed("Could not open the audio source: \(message)") }
                    return
                }
            }
            let supported = session.canAddOutput(output)
            if supported { session.addOutput(output) }

            guard supported else {
                session.commitConfiguration()
                Task { @MainActor in delegate.failed("Movie recording is not supported by this capture session.") }
                return
            }

            let requestedDuration: CMTime
            var deviceLocked = false
            do {
                try videoDevice.lockForConfiguration()
                deviceLocked = true
                let ranges = videoDevice.activeFormat.videoSupportedFrameRateRanges
                guard let range = ranges.first(where: {
                    frameRate >= $0.minFrameRate - 0.001 && frameRate <= $0.maxFrameRate + 0.001
                }) else {
                    throw CaptureFailure.unsupportedFrameRate
                }
                let duration: CMTime
                if abs(frameRate - range.minFrameRate) < 0.01 {
                    duration = range.maxFrameDuration
                } else if abs(frameRate - range.maxFrameRate) < 0.01 {
                    duration = range.minFrameDuration
                } else {
                    duration = CMTime(value: 1_000_000, timescale: CMTimeScale((frameRate * 1_000_000).rounded()))
                }
                videoDevice.activeVideoMinFrameDuration = duration
                videoDevice.activeVideoMaxFrameDuration = duration
                requestedDuration = duration
            } catch {
                session.removeOutput(output)
                session.commitConfiguration()
                if deviceLocked { videoDevice.unlockForConfiguration() }
                let message = error.localizedDescription
                Task { @MainActor in delegate.failed("Could not set the frame rate: \(message)") }
                return
            }

            session.commitConfiguration()
            videoDevice.unlockForConfiguration()

            guard CMTimeCompare(videoDevice.activeVideoMinFrameDuration, requestedDuration) == 0,
                  CMTimeCompare(videoDevice.activeVideoMaxFrameDuration, requestedDuration) == 0 else {
                session.beginConfiguration()
                session.removeOutput(output)
                session.commitConfiguration()
                Task { @MainActor in delegate.failed("The capture session did not retain the selected frame rate.") }
                return
            }

            output.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func stopRecording(_ output: AVCaptureMovieFileOutput) {
        queue.async { output.stopRecording() }
    }

    func start() {
        let session = session
        queue.async { session.startRunning() }
    }

    deinit {
        let session = session
        queue.async {
            session.stopRunning()
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            session.commitConfiguration()
        }
    }
}

enum CaptureFailure: LocalizedError {
    case unsupported
    case unsupportedFrameRate
    case metalUnavailable
    
    var errorDescription: String? {
        switch self {
        case .unsupported: "This device or its video output cannot be added to a capture session."
        case .unsupportedFrameRate: "The selected frame rate is no longer supported by this video format."
        case .metalUnavailable: "Metal is unavailable, so the video preview cannot be displayed."
    
        }
    }
}

@Observable
final class CaptureModel {
    enum Screen {
        case devices
        case opening(String)
        case detail(AVCaptureDevice, CaptureResource)
        case record(AVCaptureDevice, MovieRecording)

        var capture: (AVCaptureDevice, CaptureResource)? {
            switch self {
            case let .detail(device, resource): (device, resource)
            case let .record(device, recording): (device, recording.resource)
            default: nil
            }
        }
    }

    var devices: [AVCaptureDevice] = []
    var audioDevices: [AVCaptureDevice] = []
    var selectedAudioID = ""
    var selectedFrameRate = 0.0
    var selectedFrameRateExceedsRecordingLimit: Bool {
        // Match the picker's two-decimal display: some 30 fps modes report 30.00003.
        (selectedFrameRate * 100).rounded() > 3_000
    }
    var preparingRecording = false

    private func refreshAudio(for videoDevice: AVCaptureDevice) {
        audioDevices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified
        ).devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
        if videoDevice.hasMediaType(.audio), !audioDevices.contains(where: { $0.uniqueID == videoDevice.uniqueID }) {
            audioDevices.insert(videoDevice, at: 0)
        }
        let linked = videoDevice.linkedDevices.first { $0.hasMediaType(.audio) }
        selectedAudioID = (videoDevice.hasMediaType(.audio) ? videoDevice : linked)?.uniqueID
            ?? audioDevices.first(where: { $0.localizedName == videoDevice.localizedName })?.uniqueID
            ?? AVCaptureDevice.default(for: .audio)?.uniqueID ?? audioDevices.first?.uniqueID ?? ""
    }
    var supportedFrameRates: [Double] {
        guard case let .detail(device, _) = screen else { return [] }
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
    var screen: Screen = .devices
    var message = ""
    var permissionDenied = false
    var streamMessage = ""

    func refresh() async {
        message = ""
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                permissionDenied = true
                return
            }
        case .authorized: break
        default:
            permissionDenied = true
            return
        }
        permissionDenied = false
        devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.external, .builtInWideAngleCamera],
            mediaType: .video, position: .unspecified
        ).devices.sorted { $0.localizedName.localizedStandardCompare($1.localizedName) == .orderedAscending }
    }

    func open(_ device: AVCaptureDevice) {
        screen = .opening(device.localizedName)
        message = ""
        streamMessage = ""
        do {
            let resource = try CaptureResource(device: device)
            refreshAudio(for: device)
            screen = .detail(device, resource)
            let currentDuration = device.activeVideoMinFrameDuration.seconds
            let currentRate = currentDuration > 0 ? 1 / currentDuration : 0
            selectedFrameRate = supportedFrameRates.min(by: { abs($0 - currentRate) < abs($1 - currentRate) }) ?? 0
            resource.start()
        } catch {
            screen = .devices
            message = error.localizedDescription
        }
    }

    func record(_ device: AVCaptureDevice, resource: CaptureResource) async {
        guard !preparingRecording else { return }
        guard case let .detail(_, currentResource) = screen, currentResource === resource else { return }
        guard !selectedFrameRateExceedsRecordingLimit else {
            streamMessage = "Please choose 30 fps or lower before recording."
            return
        }
        preparingRecording = true
        defer { preparingRecording = false }
        let authorized: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: authorized = true
        case .notDetermined: authorized = await AVCaptureDevice.requestAccess(for: .audio)
        default: authorized = false
        }
        guard case let .detail(_, currentResource) = screen, currentResource === resource else { return }
        guard authorized else {
            streamMessage = "Allow microphone access in System Settings → Privacy & Security → Microphone to record audio."
            return
        }
        guard let audioDevice = audioDevices.first(where: { $0.uniqueID == selectedAudioID }) else {
            streamMessage = "No audio source is selected. Reopen the video source after connecting an audio device."
            return
        }
        guard supportedFrameRates.contains(where: { abs($0 - selectedFrameRate) < 0.01 }) else {
            streamMessage = "Select a supported frame rate before recording."
            return
        }
        streamMessage = ""
        do {
            let recording = try MovieRecording(resource: resource, audioDevice: audioDevice, frameRate: selectedFrameRate)
            screen = .record(device, recording)
            recording.start()
        } catch {
            streamMessage = error.localizedDescription
        }
    }

    func back() {
        screen = .devices
        streamMessage = ""
    }

    func disconnected(_ notification: Notification) {
        guard let (device, _) = screen.capture,
              let disconnected = notification.object as? AVCaptureDevice,
              disconnected.uniqueID == device.uniqueID else { return }
        if case let .record(_, recording) = screen {
            recording.finish()
            streamMessage = "\(device.localizedName) was disconnected. Save the recording before returning to preview."
        } else {
            back()
        }
        devices.removeAll { $0.uniqueID == device.uniqueID }
        message = "\(device.localizedName) was disconnected. Reconnect it and refresh the list."
    }

    func sessionFailed(_ notification: Notification) {
        guard let (_, resource) = screen.capture,
              let session = notification.object as? AVCaptureSession,
              session === resource.session else { return }
        streamMessage = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription
            ?? "The capture session stopped unexpectedly. Go back and reopen the device to retry."
    }
}
