import AVFoundation
import AppKit
import Observation

/// Balances the activity token automatically when the preview owner is released.
private final class PreviewActivity {
    private let token: NSObjectProtocol

    init() {
        token = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
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
    private let previewActivity: PreviewActivity
    private let queue = DispatchQueue(label: "dev.streamer.capture")

    init(device: AVCaptureDevice) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureFailure.unsupported
        }
        session.addInput(input)
        session.commitConfiguration()
        self.session = session
        previewActivity = PreviewActivity()
    }

    func record(to url: URL, output: AVCaptureMovieFileOutput, delegate: MovieRecording) {
        let session = session
        queue.async {
            session.beginConfiguration()
            let supported = session.canAddOutput(output)
            if supported { session.addOutput(output) }
            session.commitConfiguration()
            guard supported, output.connection(with: .video) != nil else {
                Task { @MainActor in delegate.failed("This source does not support movie recording.") }
                return
            }
            output.startRecording(to: url, recordingDelegate: delegate)
        }
    }

    func stopRecording(_ output: AVCaptureMovieFileOutput) {
        queue.async { output.stopRecording() }
    }

    func removeRecordingOutput(_ output: AVCaptureMovieFileOutput) {
        let session = session
        queue.async {
            session.beginConfiguration()
            if session.outputs.contains(where: { $0 === output }) { session.removeOutput(output) }
            session.commitConfiguration()
        }
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
    var errorDescription: String? { "This device cannot be added to a video capture session." }
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
            screen = .detail(device, resource)
            resource.start()
        } catch {
            screen = .devices
            message = error.localizedDescription
        }
    }

    func record(_ device: AVCaptureDevice, resource: CaptureResource) {
        do {
            let recording = try MovieRecording(resource: resource)
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
