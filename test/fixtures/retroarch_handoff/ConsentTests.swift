import XCTest

final class ConsentTests: XCTestCase {
    func testAuthorizeOnlyFixtureAppLinks() {
        let receiver = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.receiver")
        let sender = XCUIApplication(bundleIdentifier: "org.neostation.handofftest.sender")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        receiver.launch()
        sender.launchEnvironment = [
            "HANDOFF_MODE": "authorize",
            "HANDOFF_TARGET": "retroarch://library?scheme=neostation-handoff-test",
        ]
        sender.launch()
        // Standard first-use link consent for these two disposable apps.
        // No preferences/entitlements are changed to bypass this dialog.
        for _ in 0..<2 {
            let open = springboard.alerts.buttons["Open"]
            XCTAssertTrue(open.waitForExistence(timeout: 20), springboard.debugDescription)
            open.tap()
        }
        XCTAssertTrue(sender.wait(for: .runningForeground, timeout: 20))
    }
}
