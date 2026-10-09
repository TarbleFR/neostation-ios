import UIKit

@main final class Sender: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let current = RetroArchURLHandoff()
    let legacy = LegacyRetroArchURLHandoff()
    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    var events: [[String: Any]] = []
    var started = false

    func record(_ event: [String: Any]) {
        events.append(event)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result-\(ProcessInfo.processInfo.environment["HANDOFF_CASE"] ?? "setup").json")
        try! JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.rootViewController?.view.backgroundColor = .white
        let repeatButton = UIButton(type: .system)
        repeatButton.setTitle("Send same URL", for: .normal)
        repeatButton.accessibilityIdentifier = "repeat-functional-url"
        repeatButton.frame = CGRect(x: 30, y: 120, width: 260, height: 60)
        repeatButton.addTarget(self, action: #selector(sendSameURL), for: .touchUpInside)
        window?.rootViewController?.view.addSubview(repeatButton)
        window?.makeKeyAndVisible()
        return true
    }

    @objc private func sendSameURL() { run(UIApplication.shared) }

    func applicationDidBecomeActive(_ application: UIApplication) {
        record(["event": "active"])
        guard !started else { return }
        started = true
        run(application)
    }

    func run(_ app: UIApplication) {
        let env = ProcessInfo.processInfo.environment
        let target = URL(string: env["HANDOFF_TARGET"]!)!
        let mode = env["HANDOFF_MODE"]!
        record(["event": "begin", "mode": mode, "state": app.applicationState.rawValue])
        backgroundTask = app.beginBackgroundTask(withName: "Handoff reproduction") {
            self.current.cancel(); self.legacy.cancel()
        }
        let open: (URL, @escaping (Bool) -> Void) -> Void = { url, completion in
            self.record(["event": "send", "url": url.absoluteString, "state": app.applicationState.rawValue])
            app.open(url, options: [:]) { accepted in
                self.record(["event": "acceptance", "url": url.absoluteString, "accepted": accepted])
                completion(accepted)
            }
        }
        let schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
        let done: (Bool) -> Void = { accepted in
            self.record(["event": "finished", "accepted": accepted])
            if self.backgroundTask != .invalid {
                app.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid
            }
        }
        if mode == "double" {
            // Probe only: the harmless start route and the functional URL are
            // both requested in this run-loop turn, while the sender is active.
            var results: [String: Bool] = [:]
            func settle(_ key: String, _ accepted: Bool) {
                results[key] = accepted
                if results.count == 2 { done(results["functional"] ?? false) }
            }
            open(URL(string: "retroarch://start")!) { settle("start", $0) }
            open(target) { settle("functional", $0) }
            return
        }
        if mode == "legacy" {
            legacy.start(target: target, open: open, schedule: schedule, completion: done)
        } else {
            current.start(target: target, open: open, schedule: schedule,
                          isForeground: { app.applicationState == .active }, completion: done)
        }
    }
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        record(["event": "callback", "host": url.host ?? ""])
        return true
    }
}
