import AVFoundation
import Observation

/// Receives video frames on CaptureResource's dedicated frame queue.
/// Frame processing can be added here in the next scene.
final class VideoFrameDelegate: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // The asynchronous data output is active. The detail scene does not use frames yet.
    }
}

/// Owns the session and its one video data output for the lifetime of the detail scene.
final class CaptureResource: @unchecked Sendable {
    let session: AVCaptureSession
    let videoOutput: AVCaptureVideoDataOutput
    let frameDelegate: VideoFrameDelegate
    private let sessionQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.session")
    private let frameQueue = DispatchQueue(label: "com.ingun37.GuraStreaming.frames")

    init(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        let delegate = VideoFrameDelegate()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(delegate, queue: frameQueue)

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureFailure.unsupported
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()

        self.session = session
        self.videoOutput = output
        self.frameDelegate = delegate
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

    var errorDescription: String? {
        "This device or its video output cannot be added to a capture session."
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

    func open(_ device: AVCaptureDevice) {
        message = ""
        streamMessage = ""
        do {
            let resource = try CaptureResource(device: device)
            screen = .detail(device, resource)
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
