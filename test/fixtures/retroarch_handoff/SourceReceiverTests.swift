import XCTest

// Only verifies URL receipt. No playlist lookup or core is mocked as a success.
final class SourceReceiverTests: XCTestCase {
    func testSupportedRoutesColdThenWarm() {
        let receiver = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.receiver")
        let sender = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.sender")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let targets = [
            "retroarch://game/Unicode-%C3%A9.zip%23folder%2Fgame.gba",
            "retroarch://library?scheme=neostation-handoff-test",
            "retroarch://topshelf?path=~%2FDocuments%2FRetroArch%2FBiblioth%C3%A8ques%20%2Fgame.zip%23game.gba&core_path=%3A%2FFrameworks%2Fmgba.libretro.framework",
        ]
        func settle() {
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                for app in [springboard, sender, receiver] {
                    let open = app.alerts.buttons["Open"]
                    if open.exists { open.tap() }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        }
        for (index, target) in targets.enumerated() {
            sender.terminate(); receiver.terminate()
            sender.launchEnvironment = [
                "HANDOFF_MODE": "current", "HANDOFF_CASE": "source-\(index)",
                "HANDOFF_TARGET": target,
            ]
            sender.launch(); settle()
            XCTAssertTrue(receiver.wait(for: .runningForeground, timeout: 5))
            sender.activate()
            let button = sender.buttons["repeat-functional-url"]
            XCTAssertTrue(button.waitForExistence(timeout: 5))
            button.tap(); settle()
            XCTAssertTrue(receiver.wait(for: .runningForeground, timeout: 5))
        }
    }
}
