import Foundation

/// Sends one functional URL while NeoStation is active. A preliminary start
/// URL backgrounds the sender before the real request and is not a readiness
/// handshake. UIKit acceptance still does not acknowledge content execution.
final class RetroArchURLHandoff {
    typealias Open = (URL, @escaping (Bool) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private var completion: ((Bool) -> Void)?
    private var generation = 0
    private var waitingForForeground = false
    private(set) var failureReason: String?

    func start(target: URL, open: @escaping Open, schedule: @escaping Schedule,
               isForeground: @escaping () -> Bool = { true },
               completion: @escaping (Bool) -> Void) {
        guard self.completion == nil else {
            completion(false)
            return
        }
        failureReason = nil
        generation += 1
        let attempt = generation
        self.completion = completion
        waitingForForeground = true
        schedule(5) { [weak self] in
            guard let self = self else { return }
            self.finish(false, attempt: attempt,
                        reason: self.waitingForForeground ? "foreground_timeout" : "handoff_timeout")
        }
        sendWhenActive(target: target, open: open, schedule: schedule,
                       isForeground: isForeground, attempt: attempt)
    }

    // A library callback or a UI transition can finish before UIKit activates
    // NeoStation. Never spend that interval sending the URL from background.

    private func sendWhenActive(target: URL, open: @escaping Open,
                                schedule: @escaping Schedule,
                                isForeground: @escaping () -> Bool, attempt: Int) {
        guard generation == attempt, completion != nil else { return }
        guard isForeground() else {
            schedule(0.05) { [weak self] in
                self?.sendWhenActive(target: target, open: open, schedule: schedule,
                                     isForeground: isForeground, attempt: attempt)
            }
            return
        }
        waitingForForeground = false
        open(target) { [weak self] accepted in
            self?.finish(accepted, attempt: attempt,
                         reason: accepted ? nil : "functional_url_rejected")
        }
    }

    func cancel() { finish(false, attempt: generation, reason: "background_task_expired") }

    private func finish(_ opened: Bool, attempt: Int, reason: String? = nil) {
        guard generation == attempt, let callback = completion else { return }
        failureReason = reason
        NSLog("[RetroArch handoff] attempt=%d accepted=%@ reason=%@", attempt, opened ? "true" : "false", reason ?? "none")
        completion = nil
        callback(opened)
    }
}
