// Regression fixture copied from af0d539, class name only changed.
import Foundation

/// RetroArch's SceneDelegate drops connectionOptions.URLContexts on a cold
/// launch. Open its harmless start route first, then send ONE functional URL
/// to the running scene. The plugin holds a finite UIKit background task for
/// this sequence; a Dart timer alone would be suspended during the handoff.
final class LegacyRetroArchURLHandoff {
    typealias Open = (URL, @escaping (Bool) -> Void) -> Void
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> Void
    private var completion: ((Bool) -> Void)?
    private var generation = 0

    func start(target: URL, open: @escaping Open, schedule: @escaping Schedule,
               completion: @escaping (Bool) -> Void) {
        guard self.completion == nil else {
            completion(false)
            return
        }
        generation += 1
        let attempt = generation
        self.completion = completion
        schedule(5) { [weak self] in self?.finish(false, attempt: attempt) }
        open(URL(string: "retroarch://start")!) { [weak self] opened in
            guard let self = self, self.generation == attempt, self.completion != nil else { return }
            guard opened else { self.finish(false, attempt: attempt); return }
            schedule(1) { [weak self] in
                guard let self = self, self.generation == attempt, self.completion != nil else { return }
                open(target) { [weak self] accepted in self?.finish(accepted, attempt: attempt) }
            }
        }
    }

    func cancel() { finish(false, attempt: generation) }

    private func finish(_ opened: Bool, attempt: Int) {
        guard generation == attempt, let callback = completion else { return }
        completion = nil
        callback(opened)
    }
}
