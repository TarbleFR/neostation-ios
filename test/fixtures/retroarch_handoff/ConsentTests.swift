import XCTest

final class ConsentTests: XCTestCase {
    func testTransportFromFixtureApps() {
        let receiver = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.receiver")
        let sender = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.sender")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let cases = [("legacy", "library", false), ("legacy", "game", false),
                     ("current", "library", false), ("current", "game", false),
                     ("current", "library", true)]
        for (index, scenario) in cases.enumerated() {
            sender.terminate(); receiver.terminate()
            receiver.launchEnvironment = ["HANDOFF_CASE": String(index)]
            if !scenario.2 { receiver.launch() }
            sender.launchEnvironment = [
                "HANDOFF_MODE": scenario.0, "HANDOFF_CASE": String(index),
                "HANDOFF_TARGET": scenario.1 == "library"
                    ? "retroarch://library?scheme=neostation-handoff-test"
                    : "retroarch://game/Unicode-%C3%A9.zip%23folder%2Fgame.gba",
            ]
            sender.launch()
            // XCTest may allow its managed apps to open links without a
            // prompt. If a normal system confirmation appears, tap Open.
            // Transport assertions read actual sender/receiver files in the
            // Python driver after these UI operations; no open result is mocked.
            let deadline = Date().addingTimeInterval(8)
            while Date() < deadline {
                for app in [springboard, sender, receiver] {
                    let open = app.alerts.buttons["Open"]
                    if open.exists { open.tap() }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "transport-\(index)"; screen.lifetime = .keepAlways
            add(screen)
        }
    }
}
