import UIKit

@main final class Sender: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let current = RetroArchURLHandoff()
    let legacy = LegacyRetroArchURLHandoff()
    var backgroundTask = UIBackgroundTaskIdentifier.invalid
    var events: [[String: Any]] = []

    func record(_ event: [String: Any]) {
        events.append(event)
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("result.json")
        try! JSONSerialization.data(withJSONObject: events, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }

    func application(_ app: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.rootViewController?.view.backgroundColor = .white
        window?.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.run(app) }
        return true
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
