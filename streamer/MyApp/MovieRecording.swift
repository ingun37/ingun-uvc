import AVFoundation
import Observation

/// Owns one temporary movie and keeps its capture session alive through finalization.
@Observable
final class MovieRecording: NSObject, AVCaptureFileOutputRecordingDelegate {
    enum Phase {
        case starting, recording, finishing, ready, failed

        var label: String {
            switch self {
            case .starting: "Starting recording…"
            case .recording: "Recording"
            case .finishing: "Finishing recording…"
            case .ready: "Recording complete — click Done to save"
            case .failed: "Recording failed"
            }
        }
    }

    let resource: CaptureResource
    let url: URL
    private let directory: URL
    private let output = AVCaptureMovieFileOutput()
    var phase: Phase = .starting
    var message = ""
    var saveRequested = false

    init(resource: CaptureResource) throws {
        self.resource = resource
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Recording.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()
    }

    func start() {
        resource.record(to: url, output: output, delegate: self)
    }

    func finish() {
        if phase == .starting {
            phase = .finishing
            return
        }
        guard phase == .recording else { return }
        saveRequested = true
        phase = .finishing
        resource.stopRecording(output)
    }

    func failed(_ message: String) {
        self.message = message
        phase = .failed
        resource.removeRecordingOutput(output)
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection]) {
        Task { @MainActor in
            if self.phase == .finishing { self.resource.stopRecording(self.output) }
            else if self.phase == .starting { self.phase = .recording }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection], error: Error?) {
        let failure = error as NSError?
        let successful = failure == nil || (failure?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true)
        let message = failure?.localizedDescription ?? ""
        Task { @MainActor in
            self.resource.removeRecordingOutput(self.output)
            self.message = message
            self.phase = successful ? .ready : .failed
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
