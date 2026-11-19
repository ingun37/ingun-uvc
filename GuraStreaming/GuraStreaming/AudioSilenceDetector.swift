import Foundation

/// A wall-clock timer also catches sources that deliver no audio buffers at all.
/// All timer state lives on its own queue; capture callbacks never wait for it.
nonisolated final class AudioSilenceDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ingun37.GuraStreaming.audioSilence", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var timeout: TimeInterval = 60

    func start(timeout: TimeInterval, onTimeout: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            timer?.cancel()
            self.timeout = timeout
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler { [weak self] in
                guard let self else { return }
                self.timer?.cancel()
                self.timer = nil
                onTimeout()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func heardSound() {
        queue.async { [self] in
            guard let timer else { return }
            timer.schedule(deadline: .now() + timeout)
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
        }
    }
}
