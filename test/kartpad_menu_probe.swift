import XCTest
import ObjectiveC.runtime

final class KartPadMenuProbe: XCTestCase {
  func testImmediateRelaunchFromNativeMenu() {
    continueAfterFailure = false
    // XCTest's animation-idle gate waits 60 seconds on the continuously
    // rendering SDL window. Keep event-loop quiescence, but send taps without
    // waiting for that animation gate. This changes only the test runner;
    // UIKit animations and the app under test remain untouched.
    guard let processClass = NSClassFromString("XCUIApplicationProcess") else {
      return XCTFail("XCTest process class unavailable")
    }
    let single = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:")
    let paired = NSSelectorFromString("waitForQuiescenceIncludingAnimationsIdle:isPreEvent:")
    if let method = class_getInstanceMethod(processClass, single) {
      typealias Wait = @convention(c) (AnyObject, Selector, Bool) -> Void
      let original = unsafeBitCast(method_getImplementation(method), to: Wait.self)
      let replacement: @convention(block) (AnyObject, Bool) -> Void = { process, _ in
        original(process, single, false)
      }
      method_setImplementation(method, imp_implementationWithBlock(replacement))
    } else if let method = class_getInstanceMethod(processClass, paired) {
      typealias Wait = @convention(c) (AnyObject, Selector, Bool, Bool) -> Void
      let original = unsafeBitCast(method_getImplementation(method), to: Wait.self)
      let replacement: @convention(block) (AnyObject, Bool, Bool) -> Void = { process, _, preEvent in
        original(process, paired, false, preEvent)
      }
      method_setImplementation(method, imp_implementationWithBlock(replacement))
    } else {
      return XCTFail("XCTest quiescence API changed; cannot test immediate taps")
    }
    let app = XCUIApplication()
    app.launchArguments = ["--menu-probe", "--fiber-probe"]
    // Keep Main Thread Checker reports, but let this observational lifecycle
    // probe reach its menu assertions. The shipped renderer reads SDL window
    // size on its frame worker; XCTest otherwise aborts before the first tap.
    app.launchEnvironment["MTC_CRASH_ON_REPORT"] = "0"
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
