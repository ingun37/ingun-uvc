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

    func start() { resource.startRecording(self) }

    func stop() {
        switch phase {
        case .starting:
            phase = .stopping
            message = "Stopping recording…"
        case .recording:
            phase = .stopping
            message = "Finishing recording…"
            resource.stopRecording(output)
        default: break
        }
    }

    func failed(_ reason: String) {
        phase = .failed
        message = reason
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection]) {
        Task { @MainActor [self] in
            if phase == .stopping {
                resource.stopRecording(self.output)
            } else if phase == .starting {
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
            resource.removeRecordingOutput(self.output)
            guard success else {
                failed(failureText)
                return
            }
            phase = .saved
            message = "Video is saved to \(outputFileURL.path)"
            print(message)
        }
    }
}
