import Foundation

final class Clock {
    var now: TimeInterval = 0
    var tasks: [(TimeInterval, () -> Void)] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { tasks.append((now + delay, action)) }
    func advance(_ interval: TimeInterval) {
        let end = now + interval
        while let next = tasks.enumerated().filter({ $0.element.0 <= end }).min(by: { $0.element.0 < $1.element.0 }) {
            tasks.remove(at: next.offset)
            now = next.element.0
            next.element.1()
        }
        now = end
    }
}

@main struct Tests {
    static func main() {
        var cases = 0
        for target in ["retroarch://library?scheme=neostation", "retroarch://game/Pok%C3%A9mon.zip%23Pok%C3%A9mon.gbc"] {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var opened: [String] = [], completed: [Bool] = [], foreground = true
            handoff.start(target: URL(string: target)!, open: { url, callback in
                // Model the foreground restriction; UIKit is exercised separately.
                guard foreground else { callback(false); return }
                opened.append(url.absoluteString)
                foreground = false
                callback(true)
            }, schedule: clock.schedule, isForeground: { foreground }, completion: { completed.append($0) })
            assert(opened == [target] && completed == [true])
            clock.advance(10)
            assert(opened == [target] && completed == [true]); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = [], opened = 0
            handoff.start(target: URL(string: "retroarch://library?scheme=neostation")!, open: { _, callback in
                opened += 1; callback(false)
            }, schedule: clock.schedule, completion: { completed.append($0) })
            clock.advance(10)
            assert(opened == 1 && completed == [false])
            assert(handoff.failureReason == "functional_url_rejected"); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = [], opened = 0
            var delayed: ((Bool) -> Void)?
            let url = URL(string: "retroarch://game/A.gba")!
            handoff.start(target: url, open: { _, callback in opened += 1; delayed = callback }, schedule: clock.schedule,
                          completion: { completed.append($0) })
            handoff.start(target: url, open: { _, _ in fatalError("duplicate open") }, schedule: clock.schedule,
                          completion: { completed.append($0) })
            assert(completed == [false])
            handoff.cancel(); delayed?(true); clock.advance(10)
            assert(opened == 1 && completed == [false, false])
            assert(handoff.failureReason == "background_task_expired"); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = []
            var stale: ((Bool) -> Void)?
            let url = URL(string: "retroarch://game/A.gba")!
            handoff.start(target: url, open: { _, callback in stale = callback }, schedule: clock.schedule, completion: { completed.append($0) })
            clock.advance(5)
            assert(completed == [false] && handoff.failureReason == "handoff_timeout")
            handoff.start(target: url, open: { _, callback in callback(true) }, schedule: clock.schedule, completion: { completed.append($0) })
            stale?(true); clock.advance(10)
            assert(completed == [false, true] && handoff.failureReason == nil); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var foreground = false, opened: [String] = [], completed: [Bool] = []
            let url = URL(string: "retroarch://game/A.gba")!
            handoff.start(target: url, open: { target, callback in
                opened.append(target.absoluteString); callback(true)
            }, schedule: clock.schedule, isForeground: { foreground }, completion: { completed.append($0) })
            clock.advance(1)
            assert(opened.isEmpty && completed.isEmpty)
            foreground = true; clock.advance(0.1)
            assert(opened == [url.absoluteString] && completed == [true])
            clock.advance(10)
            assert(opened.count == 1 && completed.count == 1); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var foreground = false, opened = 0, completed: [Bool] = []
            handoff.start(target: URL(string: "retroarch://game/A.gba")!, open: { _, _ in opened += 1 },
                          schedule: clock.schedule, isForeground: { foreground }, completion: { completed.append($0) })
            clock.advance(5)
            assert(opened == 0 && completed == [false] && handoff.failureReason == "foreground_timeout")
            foreground = true; clock.advance(10)
            assert(opened == 0 && completed.count == 1); cases += 1
        }
        print("RetroArch URL handoff: \(cases) behavior cases passed; no game execution is simulated")
    }
}
