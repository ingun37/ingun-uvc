import Foundation

/// A wall-clock timer also catches sources that deliver no audio buffers at all.
/// All timer state lives on its own queue; capture callbacks never wait for it.
nonisolated final class AudioSilenceDetector: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.ingun37.GuraStreaming.audioSilence", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var timeout: TimeInterval = 60
    private var deadline = 0.0
    private var lastRemaining: Int?
    private var onCountdown: (@Sendable (Int?) -> Void)?
    private var onTimeout: (@Sendable () -> Void)?

    func start(timeout: TimeInterval, onCountdown: @escaping @Sendable (Int?) -> Void,
               onTimeout: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            timer?.cancel()
            self.timeout = timeout
            self.deadline = ProcessInfo.processInfo.systemUptime + timeout
            self.onCountdown = onCountdown
            self.onTimeout = onTimeout
            self.lastRemaining = Int(ceil(timeout))
            onCountdown(lastRemaining)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + min(1, timeout))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        }
    }

    func heardSound() {
        queue.async { [self] in
            guard let timer else { return }
            deadline = ProcessInfo.processInfo.systemUptime + timeout
            timer.schedule(deadline: .now() + min(1, timeout))
            if lastRemaining != nil {
                lastRemaining = nil
                onCountdown?(nil)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            onCountdown = nil
            onTimeout = nil
            lastRemaining = nil
        }
    }

    private func tick() {
        guard let timer else { return }
        let remainingTime = deadline - ProcessInfo.processInfo.systemUptime
        if remainingTime <= 0 {
            timer.cancel()
            self.timer = nil
            onTimeout?()
            onCountdown = nil
            onTimeout = nil
            return
        }
        let remaining = Int(ceil(remainingTime))
        if remaining != lastRemaining {
            lastRemaining = remaining
            onCountdown?(remaining)
        }
        timer.schedule(deadline: .now() + min(1, remainingTime))
    }
}
