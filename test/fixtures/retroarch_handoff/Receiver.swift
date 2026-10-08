import UIKit

// A URL receiver, not an emulator. Mirrors the inspected RetroArch scene's
// warm URL routing and cold URL omission; no content/core execution is claimed.
@main final class Receiver: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?) -> Bool { true }
}
final class ReceiverScene: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        window = UIWindow(windowScene: scene as! UIWindowScene)
        window?.rootViewController = UIViewController()
        window?.rootViewController?.view.backgroundColor = .green
        window?.makeKeyAndVisible()
        let initial = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("initial-urls.json")
        try! JSONSerialization.data(withJSONObject: options.urlContexts.map { $0.url.absoluteString }).write(to: initial, options: .atomic)
        // Test-only control for the proposed receiver fix. The default still
        // reproduces the upstream omission and is used by existing controls.
        if Bundle.main.object(forInfoDictionaryKey: "FixtureHandlesInitialURLs") as? Bool == true {
            DispatchQueue.main.async { self.scene(scene, openURLContexts: options.urlContexts) }
        }
    }
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("received-\(ProcessInfo.processInfo.environment["HANDOFF_CASE"] ?? "cold").json")
        var received = (try? JSONSerialization.jsonObject(with: Data(contentsOf: file))) as? [String] ?? []
        for context in contexts {
            received.append(context.url.absoluteString)
            if context.url.host == "library" {
                // Use only the synthetic sender's scheme, never a user's app.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    UIApplication.shared.open(URL(string: "neostation-handoff-test://retroarch")!, options: [:])
                }
            }
        }
        try! JSONSerialization.data(withJSONObject: received).write(to: file, options: .atomic)
    }
}
