import AVFoundation
import Metal
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
    let frameRate: Double
    let url: URL
    private let directory: URL
    private let output = AVCaptureMovieFileOutput()
    
    var phase: Phase = .starting
    var message = ""
    var savedURL: URL?
    var freezeTimeout = 48
    var freezeDeadline: TimeInterval?

    init(resource: CaptureResource, audioDevice: AVCaptureDevice, frameRate: Double) throws {

        self.resource = resource
        self.audioDevice = audioDevice
        self.frameRate = frameRate
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        url = directory.appendingPathComponent("Recording.mov")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        super.init()

    }

    func start() {
        resource.record(to: url, audioDevice: audioDevice, frameRate: frameRate, output: output, delegate: self)
    }

    func finish(reason: String = "") {
        if !reason.isEmpty { message = reason }
        resource.preview.stopFreezeDetection()
        freezeDeadline = nil
        if phase == .starting {
            phase = .finishing
            return
        }
        guard phase == .recording else { return }
        phase = .finishing
        
        resource.stopRecording(output)
    }

    func failed(_ message: String) {
        resource.preview.stopFreezeDetection()
        freezeDeadline = nil
        self.message = message
        phase = .failed
        
        
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection]) {
        Task { @MainActor [self] in
            if self.phase == .finishing { self.resource.stopRecording(self.output) }
            else if self.phase == .starting {
                self.phase = .recording
                do {
                    try self.resource.preview.startFreezeDetection { [weak self] duration in
                        Task { @MainActor [weak self] in self?.updateFreeze(duration) }
                    }
                } catch {
                    self.finish(reason: "Could not monitor frozen video: \(error.localizedDescription)")
                }
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
            self.resource.preview.stopFreezeDetection()
            self.freezeDeadline = nil
            
            if !message.isEmpty { self.message = message }
            self.phase = successful ? .ready : .failed
            if successful { self.save() }
        }
    }

    private func updateFreeze(_ duration: TimeInterval?) {
        guard phase == .recording else { return }
        guard let duration else {
            freezeDeadline = nil
            return
        }
        freezeDeadline = ProcessInfo.processInfo.systemUptime + Double(freezeTimeout) - duration
        if duration >= Double(freezeTimeout) {
            finish(reason: "Recording stopped because the video was frozen for \(freezeTimeout) seconds.")
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
