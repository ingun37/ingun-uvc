import AVFoundation
import Observation

/// Owns a movie output and reports success only after AVFoundation finalizes it.
@Observable
final class MovieRecording: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Phase {
        case starting, recording, stopping, saved, failed

        var isBusy: Bool {
            switch self {
            case .starting, .recording, .stopping: true
            case .saved, .failed: false
            }
        }
    }

    let resource: CaptureResource
    let output = AVCaptureMovieFileOutput()
    let destinationURL: URL
    var phase: Phase = .starting
    var message = "Starting recording…"
    var freezeCountdown: Int?
    var stopReason = "Stopped by clicking Stop"
    var savedURL: URL?
    @ObservationIgnored private var maskLogTask: Task<String?, Never>?

    init(resource: CaptureResource) throws {
        self.resource = resource
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        try FileManager.default.createDirectory(at: movies, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let base = formatter.string(from: Date())
        var destination = movies.appendingPathComponent("\(base).mov")
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = movies.appendingPathComponent("\(base)-\(suffix).mov")
            suffix += 1
        }
        destinationURL = destination
        super.init()
    }

    func start(freezeTimeout: TimeInterval) {
        let detector = resource.freezeDetector
        detector.timeout = freezeTimeout
        detector.onCountdown = { [weak self] remaining in
            Task { @MainActor [weak self] in self?.freezeCountdown = remaining }
        }
        detector.onTimeout = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.phase == .recording else { return }
                self.stop(reason: "Stopped because the video was frozen")
                self.message = "Recording stopped because video was frozen. Finishing…"
            }
        }
        detector.setActive(true)
        resource.startRecording(self)
    }

    func stop(reason: String = "Stopped by clicking Stop") {
        stopReason = reason
        resource.freezeDetector.setActive(false)
        freezeCountdown = nil
        switch phase {
        case .starting:
            phase = .stopping
            message = "Stopping recording…"
        case .recording:
            phase = .stopping
            message = "Finishing recording…"
            finishMaskLog()
            resource.stopRecording(output)
        default: break
        }
    }

    func failed(_ reason: String) {
        resource.freezeDetector.setActive(false)
        resource.renderer.discardMaskLogging()
        phase = .failed
        message = "Stopped because of an error: \(reason)"
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor [self] in
            if phase == .stopping {
                resource.renderer.startMaskLogging()
                finishMaskLog()
                resource.stopRecording(self.output)
            } else if phase == .starting {
                resource.renderer.startMaskLogging()
                phase = .recording
                message = "Recording…"
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection], error: Error?) {
        let failure = error as NSError?
        let success = failure == nil || (failure?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        let failureText = failure?.localizedDescription ?? "Recording did not finish successfully."
        Task { @MainActor [self] in
            resource.freezeDetector.setActive(false)
            resource.removeRecordingOutput(self.output)
            guard success else {
                failed(failureText)
                return
            }
            let csv = await (maskLogTask ?? Task { await resource.renderer.endMaskLogging() }).value
            phase = .saved
            savedURL = outputFileURL
            message = "\(stopReason). Video is saved to \(outputFileURL.path)"
            print(message)
            if let csv {
                let csvURL = outputFileURL.deletingLastPathComponent()
                    .appendingPathComponent("\(outputFileURL.deletingPathExtension().lastPathComponent)-masking-test.csv")
                do {
                    try await Task.detached {
                        try csv.write(to: csvURL, atomically: true, encoding: .utf8)
                    }.value
                    message += " Mask test CSV is saved to \(csvURL.path)"
                } catch {
                    message += " Could not save mask test CSV: \(error.localizedDescription)"
                }
            }
        }
    }

    private func finishMaskLog() {
        if maskLogTask == nil {
            maskLogTask = Task { await resource.renderer.endMaskLogging() }
        }
    }
}
