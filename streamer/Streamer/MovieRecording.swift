import AVFoundation
import Observation

/// Owns one temporary movie and keeps its capture session alive through finalization.
@Observable
final class MovieRecording: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Phase {
        case starting, recording, finishing, ready, saved, failed

        var label: String {
            switch self {
            case .starting: "Starting recording…"
            case .recording: "Recording"
            case .finishing: "Finishing recording…"
            case .ready: "Recording complete — saving failed"
            case .saved: "Recording saved"
            case .failed: "Recording failed"
            }
        }
    }

    let resource: CaptureResource
    let audioDevice: AVCaptureDevice
    let url: URL
    private let directory: URL
    private let output = AVCaptureMovieFileOutput()
    @ObservationIgnored private let monitor = VideoFreezeMonitor()
    var phase: Phase = .starting
    var message = ""
    var savedURL: URL?

    init(resource: CaptureResource, audioDevice: AVCaptureDevice) throws {
        self.resource = resource
        self.audioDevice = audioDevice
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Recording.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
        monitor.setOnFreeze { [weak self] in
            Task { @MainActor [weak self] in
                self?.finish(reason: "The video stream was frozen for more than 10 seconds.")
            }
        }
    }

    func start() {
        resource.record(to: url, audioDevice: audioDevice, output: output, monitor: monitor, delegate: self)
    }

    func finish(reason: String = "") {
        if !reason.isEmpty { message = reason }
        if phase == .starting {
            phase = .finishing
            return
        }
        guard phase == .recording else { return }
        phase = .finishing
        monitor.stop()
        resource.stopRecording(output)
    }

    func failed(_ message: String) {
        self.message = message
        phase = .failed
        monitor.stop()
        resource.removeRecordingOutput(output, monitor: monitor)
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            if self.phase == .finishing { self.resource.stopRecording(self.output) }
            else if self.phase == .starting {
                self.phase = .recording
                self.monitor.start()
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection], error: Error?) {
        let failure = error as NSError?
        let successful = failure == nil || (failure?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        let message = failure.map { error in
            ["\(error.localizedDescription) (\(error.domain), \(error.code))",
             error.localizedFailureReason, error.localizedRecoverySuggestion,
             (error.userInfo[NSUnderlyingErrorKey] as? NSError).map { "Underlying error: \($0)" }]
                .compactMap { $0 }.joined(separator: "\n")
        } ?? ""
        Task { @MainActor in
            self.monitor.stop()
            self.resource.removeRecordingOutput(self.output, monitor: self.monitor)
            if !message.isEmpty { self.message = message }
            self.phase = successful ? .ready : .failed
            if successful { self.save() }
        }
    }

    func save() {
        guard phase == .ready else { return }
        do {
            let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
            let name = formatter.string(from: Date())
            var destination = movies.appendingPathComponent("\(name).mov")
            var suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = movies.appendingPathComponent("\(name)-\(suffix).mov")
                suffix += 1
            }
            try FileManager.default.moveItem(at: url, to: destination)
            savedURL = destination
            phase = .saved
        } catch {
            message = "Could not save the recording: \(error.localizedDescription). Click Done to retry."
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
