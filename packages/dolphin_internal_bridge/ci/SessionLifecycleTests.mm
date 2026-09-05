#import <XCTest/XCTest.h>
#import "DolphinSessionLifecycle.h"

@interface SessionLifecycleTests : XCTestCase
@end

@implementation SessionLifecycleTests

- (void)present:(UIViewController*)controller from:(UIViewController*)presenter {
  XCTestExpectation* presented = [self expectationWithDescription:@"Session presented"];
  [presenter presentViewController:controller animated:NO completion:^{ [presented fulfill]; }];
  [self waitForExpectations:@[presented] timeout:5];
}

- (void)checkQuitWithSettings:(BOOL)settingsOpen {
  UIWindow* window = [(id)UIApplication.sharedApplication.delegate window];
  UIViewController* frontend = window.rootViewController;
  XCTAssertNil(frontend.presentedViewController);
  UIViewController* game = [UIViewController new];
  game.modalPresentationStyle = UIModalPresentationFullScreen;
  [self present:game from:frontend];
  UINavigationController* settings = nil;
  if (settingsOpen) {
    settings = [[UINavigationController alloc] initWithRootViewController:[UIViewController new]];
    settings.modalPresentationStyle = UIModalPresentationOverFullScreen;
    [self present:settings from:game];
    XCTAssertNotNil(game.view.window);
  }
  XCTestExpectation* dismissed = [self expectationWithDescription:@"Teardown completed before next launch"];
  DOLDismissSessionController(game, ^{
    XCTAssertNil(frontend.presentedViewController);
    XCTAssertNil(game.view.window);
    [dismissed fulfill];
  });
  [self waitForExpectations:@[dismissed] timeout:5];
  XCTNSPredicateExpectation* returned = [[XCTNSPredicateExpectation alloc]
      initWithPredicate:[NSPredicate predicateWithFormat:@"presentedViewController == nil"] object:frontend];
  [self waitForExpectations:@[returned] timeout:5];
  XCTAssertNil(game.presentingViewController);
  XCTAssertNil(game.view.window);
  XCTAssertNil(settings.presentingViewController);
  XCTAssertNotNil(frontend.view.window);
}

- (void)testQuitFromSettingsReturnsToFrontend { [self checkQuitWithSettings:YES]; }
- (void)testQuitFromGameReturnsToFrontend { [self checkQuitWithSettings:NO]; }

- (void)testRepeatedConsoleTransitionsWaitForFullDismissal {
  for (NSInteger transition = 0; transition < 6; ++transition)
    [self checkQuitWithSettings:transition % 2 == 0];
}

- (void)testStopWhileSettingsAreStillAppearingWaitsForTransition {
  UIWindow* window = [(id)UIApplication.sharedApplication.delegate window];
  UIViewController* frontend = window.rootViewController;
  UIViewController* game = [UIViewController new];
  game.modalPresentationStyle = UIModalPresentationFullScreen;
  [self present:game from:frontend];
  UIViewController* settings = [UIViewController new];
  settings.modalPresentationStyle = UIModalPresentationOverFullScreen;
  [game presentViewController:settings animated:YES completion:nil];
  XCTestExpectation* dismissed = [self expectationWithDescription:@"Pending settings transition closed"];
  DOLDismissSessionController(game, ^{
    XCTAssertNil(frontend.presentedViewController);
    XCTAssertNil(game.view.window);
    XCTAssertNil(settings.view.window);
    [dismissed fulfill];
  });
  [self waitForExpectations:@[dismissed] timeout:5];
}

- (void)testAbsentSessionCompletesTeardown {
  __block BOOL finished = NO;
  DOLDismissSessionController(nil, ^{ finished = YES; });
  XCTAssertTrue(finished);
}

@end
