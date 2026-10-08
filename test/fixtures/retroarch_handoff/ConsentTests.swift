import XCTest

final class ConsentTests: XCTestCase {
    func testSameURLAfterReturnAndReceiverTermination() {
        let receiver = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.receiver")
        let sender = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.sender")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func settle() {
            let deadline = Date().addingTimeInterval(4)
            while Date() < deadline {
                for app in [springboard, sender, receiver] {
                    let open = app.alerts.buttons["Open"]
                    if open.exists { open.tap() }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        sender.terminate(); receiver.terminate()
        receiver.launchEnvironment = ["HANDOFF_CASE": "relaunch"]
        receiver.launch()
        sender.launchEnvironment = [
            "HANDOFF_MODE": "current", "HANDOFF_CASE": "relaunch",
            "HANDOFF_TARGET": "retroarch://game/007%20-%20Everything%20or%20Nothing%20(USA,%20Europe)%20(En,Fr,De).zip%23007%20-%20Everything%20or%20Nothing%20(USA,%20Europe)%20(En,Fr,De).gba",
        ]
        sender.launch(); settle()
        sender.activate()
        let repeatButton = sender.buttons["repeat-functional-url"]
        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        repeatButton.tap(); settle()
        // Same sender object, same encoded URL; only the receiver's process
        // changes. This corresponds to swiping its card out in the video.
        receiver.terminate(); sender.activate()
        XCTAssertTrue(repeatButton.waitForExistence(timeout: 5))
        repeatButton.tap(); settle()
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "same-url-after-receiver-termination"; screen.lifetime = .keepAlways
        add(screen)
    }

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
