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
            var opened: [String] = [], completed: [Bool] = [], running = false, delivered = 0
            handoff.start(target: URL(string: target)!, open: { url, callback in
                opened.append(url.absoluteString)
                // Reproduce upstream: a cold scene drops the initial URL.
                if running && url.host != "start" { delivered += 1 }
                running = true
                callback(true)
            }, schedule: clock.schedule, completion: { completed.append($0) })
            assert(opened == ["retroarch://start"] && completed.isEmpty)
            clock.advance(1)
            assert(opened == ["retroarch://start", target] && delivered == 1 && completed == [true])
            clock.advance(10)
            assert(completed == [true])
            cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = [], opened = 0
            handoff.start(target: URL(string: "retroarch://library?scheme=neostation")!, open: { _, callback in
                opened += 1; callback(false)
            }, schedule: clock.schedule, completion: { completed.append($0) })
            clock.advance(10)
            assert(opened == 1 && completed == [false]); cases += 1
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
            handoff.cancel()
            delayed?(true)
            clock.advance(10)
            assert(opened == 1 && completed == [false, false]); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = []
            let url = URL(string: "retroarch://game/A.gba")!
            handoff.start(target: url, open: { _, _ in }, schedule: clock.schedule, completion: { completed.append($0) })
            clock.advance(5)
            assert(completed == [false])
            handoff.start(target: url, open: { _, callback in callback(true) }, schedule: clock.schedule,
                          completion: { completed.append($0) })
            clock.advance(1)
            assert(completed == [false, true]); cases += 1
        }
        do {
            let handoff = RetroArchURLHandoff(), clock = Clock()
            var completed: [Bool] = []
            handoff.start(target: URL(string: "retroarch://library?scheme=neostation")!, open: { url, callback in
                callback(url.host == "start")
            }, schedule: clock.schedule, completion: { completed.append($0) })
            clock.advance(1)
            assert(completed == [false]); cases += 1
        }
        print("RetroArch URL handoff: \(cases) behavior cases passed; UIKit/device validation still required")
    }
}
