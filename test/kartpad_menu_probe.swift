import XCTest

final class KartPadMenuProbe: XCTestCase {
  func testImmediateRelaunchFromNativeMenu() {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchArguments = ["--menu-probe"]
    app.launch()
    for cycle in 0..<5 {
      let gear = app.buttons["probe.settings.\(cycle)"]
      XCTAssertTrue(gear.waitForExistence(timeout: 40), "Missing settings in cycle \(cycle)")
      gear.tap()
      let exit = app.buttons["Return to NeoStation"]
      XCTAssertTrue(exit.waitForExistence(timeout: 5))
      exit.tap()
      // Ensure the previous session's control disappears before the next tap.
      let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: gear)
      XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed)
    }
    XCTAssertTrue(app.staticTexts["success"].waitForExistence(timeout: 15))
  }
}
