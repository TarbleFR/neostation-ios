#import <XCTest/XCTest.h>
#import "DolphinSessionMenu.h"

@interface DOLTouchOverlay : UIView
- (instancetype)initWithWii:(BOOL)wii;
- (void)updateExtension:(NSString*)name;
@end

@interface UIView (WiiPointerTesting)
- (void)handleLongPressWithGesture:(UILongPressGestureRecognizer*)gesture;
@end

@interface SimulatedPointerGesture : UILongPressGestureRecognizer
@property(nonatomic) UIGestureRecognizerState simulatedState;
@property(nonatomic) CGPoint simulatedLocation;
@end
@implementation SimulatedPointerGesture
- (UIGestureRecognizerState)state { return self.simulatedState; }
- (CGPoint)locationInView:(UIView*)view { return self.simulatedLocation; }
@end

// Keep the real row routing, loading guards and completion handling. Only
// replace the confirmation dialog so tests can approve it without UIKit internals.
@interface DolphinSessionMenu (StateOperationTesting)
- (void)confirmState:(NSDictionary*)slot load:(BOOL)load;
- (void)operateState:(NSDictionary*)slot load:(BOOL)load;
- (void)showStateMessage:(NSString*)key;
- (void)resumePressed;
@end

@interface AutoConfirmSessionMenu : DolphinSessionMenu
@property(nonatomic) NSInteger confirmationCount;
@property(nonatomic, copy) NSString* lastStateMessage;
@end
@implementation AutoConfirmSessionMenu
- (void)confirmState:(NSDictionary*)slot load:(BOOL)load {
  self.confirmationCount++;
  [self operateState:slot load:load];
}
- (void)showStateMessage:(NSString*)key {
  self.lastStateMessage = key;
  [super showStateMessage:key];
}
@end

@interface SessionMenuTests : XCTestCase
@end
@implementation SessionMenuTests

- (void)testOpeningRootNeverReadsControllerState {
  DolphinSessionMenu* menu = [DolphinSessionMenu new];
  __block NSInteger reads = 0;
  menu.readSettings = ^(BOOL wii, NSInteger slot, void (^completion)(NSDictionary*)) {
    reads++;
    completion(nil);
  };
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:menu];
  [navigation loadViewIfNeeded];
  [menu beginAppearanceTransition:YES animated:NO];
  [menu endAppearanceTransition];
  [menu.tableView reloadData];
  XCTAssertEqual(reads, 0);
  XCTAssertEqual([menu.tableView numberOfRowsInSection:0], 7);
  for (NSInteger row = 0; row < 7; ++row)
    XCTAssertNotNil([menu tableView:menu.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]]);
}

- (void)testSystemMenuOnlyOffersSupportedSessionActions {
  DolphinSessionMenu* menu = [DolphinSessionMenu new];
  menu.stateActionsAvailable = NO;
  __block BOOL resumed = NO;
  menu.resumeGame = ^{ resumed = YES; };
  [menu loadViewIfNeeded];
  XCTAssertEqual([menu tableView:menu.tableView numberOfRowsInSection:0], 5);
  NSArray* expected = @[@"graphics", @"controls", @"console", @"resume", @"quit"];
  for (NSInteger row = 0; row < expected.count; ++row)
    XCTAssertEqualObjects([menu tableView:menu.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:row inSection:0]].textLabel.text, expected[row]);
  [menu tableView:menu.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
  XCTAssertTrue(resumed);
}

- (NSDictionary*)stateSnapshotForWii:(BOOL)wii saved:(BOOL)saved {
  NSMutableArray* slots = [NSMutableArray array];
  for (NSInteger slot = 1; slot <= 10; slot++) {
    // Slot 9 represents a file whose header is incompatible with this game.
    BOOL exists = slot == 9 || (saved && slot == 10);
    [slots addObject:@{@"slot": @(slot), @"exists": @(exists),
        @"loadable": @(saved && slot == 10), @"modified": @1700000000,
        @"filename": [NSString stringWithFormat:@"%@.s%02ld", wii ? @"RMGE01" : @"GMSE01", (long)slot]}];
  }
  return @{@"slots": slots};
}

- (void)completeOnNextMainTurn:(void (^)(void))completion {
  XCTestExpectation* delivered = [self expectationWithDescription:@"Native callback delivered asynchronously"];
  dispatch_async(dispatch_get_main_queue(), ^{
    completion();
    [delivered fulfill];
  });
  [self waitForExpectationsWithTimeout:5 handler:nil];
}

- (AutoConfirmSessionMenu*)openStatePage:(NSInteger)row
                                  root:(AutoConfirmSessionMenu*)root
                            navigation:(UINavigationController*)navigation {
  [root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
  AutoConfirmSessionMenu* page = (AutoConfirmSessionMenu*)navigation.topViewController;
  XCTAssertTrue([page isKindOfClass:AutoConfirmSessionMenu.class]);
  [page loadViewIfNeeded];
  [page beginAppearanceTransition:YES animated:NO];
  [page endAppearanceTransition];
  return page;
}

- (void)testSeparateSaveAndLoadPagesForBothConsolesUseAsyncNativeOperations {
  for (NSNumber* wii in @[@NO, @YES]) {
    AutoConfirmSessionMenu* root = [AutoConfirmSessionMenu new];
    root.wii = wii.boolValue;
    root.gameTitle = wii.boolValue ? @"Super Mario Galaxy" : @"Super Mario Sunshine";
    root.labels = @{@"stateSlot": @"Slot {slot}", @"saveState": @"Save state",
        @"loadState": @"Load state", @"stateEmpty": @"Empty"};
    __block void (^finishRead)(NSDictionary*) = nil;
    __block void (^finishOperation)(BOOL) = nil;
    __block NSInteger operationCount = 0;
    __block NSInteger resumeCount = 0;
    __block BOOL expectedLoad = NO;
    root.readStates = ^(void (^completion)(NSDictionary*)) {
      XCTAssertNil(finishRead, @"A page must not issue overlapping reads");
      finishRead = [completion copy];
    };
    root.performStateOperation = ^(NSInteger slot, BOOL load, void (^completion)(BOOL)) {
      operationCount++;
      XCTAssertEqual(slot, 10);
      XCTAssertEqual(load, expectedLoad);
      finishOperation = [completion copy];
    };
    root.resumeGame = ^{ resumeCount++; };
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:root];
    [navigation loadViewIfNeeded];
    [root loadViewIfNeeded];
    XCTAssertEqualObjects([root tableView:root.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:3 inSection:0]].textLabel.text, @"Save state");
    XCTAssertEqualObjects([root tableView:root.tableView cellForRowAtIndexPath:
        [NSIndexPath indexPathForRow:4 inSection:0]].textLabel.text, @"Load state");

    AutoConfirmSessionMenu* saves = [self openStatePage:3 root:root navigation:navigation];
    XCTAssertEqualObjects(saves.title, @"Save state");
    XCTAssertNotNil(finishRead);
    XCTAssertEqual([saves tableView:saves.tableView numberOfRowsInSection:0], 0);
    NSIndexPath* lastRow = [NSIndexPath indexPathForRow:9 inSection:0];
    // Input arriving while native metadata is pending must not access a missing row.
    [saves tableView:saves.tableView didSelectRowAtIndexPath:lastRow];
    XCTAssertEqual(operationCount, 0);
    void (^readCompletion)(NSDictionary*) = finishRead;
    finishRead = nil;
    [self completeOnNextMainTurn:^{ readCompletion([self stateSnapshotForWii:wii.boolValue saved:NO]); }];
    XCTAssertEqual([saves tableView:saves.tableView numberOfRowsInSection:0], 10);
    UITableViewCell* last = [saves tableView:saves.tableView cellForRowAtIndexPath:lastRow];
    XCTAssertEqualObjects(last.textLabel.text, [NSString stringWithFormat:@"%@ — Slot 10", root.gameTitle]);
    XCTAssertEqualObjects(last.detailTextLabel.text, @"Empty");

    [saves tableView:saves.tableView didSelectRowAtIndexPath:lastRow];
    XCTAssertEqual(operationCount, 1);
    XCTAssertFalse(navigation.view.userInteractionEnabled);
    [saves tableView:saves.tableView didSelectRowAtIndexPath:lastRow];
    [saves resumePressed];
    XCTAssertEqual(operationCount, 1, @"Repeated input must not overlap a native write");
    XCTAssertEqual(resumeCount, 0, @"Resume must wait until the state operation finishes");
    XCTAssertNotNil(finishOperation);
    void (^saveCompletion)(BOOL) = finishOperation;
    finishOperation = nil;
    [self completeOnNextMainTurn:^{ saveCompletion(YES); }];
    XCTAssertTrue(navigation.view.userInteractionEnabled);
    XCTAssertEqualObjects(saves.lastStateMessage, @"stateSaved");
    XCTAssertNotNil(finishRead, @"Saving must refresh slot metadata");
    readCompletion = finishRead;
    finishRead = nil;
    [self completeOnNextMainTurn:^{ readCompletion([self stateSnapshotForWii:wii.boolValue saved:YES]); }];
    last = [saves tableView:saves.tableView cellForRowAtIndexPath:lastRow];
    XCTAssertTrue([last.detailTextLabel.text containsString:wii.boolValue ? @"RMGE01.s10" : @"GMSE01.s10"]);

    [navigation popToRootViewControllerAnimated:NO];
    AutoConfirmSessionMenu* loads = [self openStatePage:4 root:root navigation:navigation];
    XCTAssertEqualObjects(loads.title, @"Load state");
    XCTAssertNotNil(finishRead);
    readCompletion = finishRead;
    finishRead = nil;
    [self completeOnNextMainTurn:^{ readCompletion([self stateSnapshotForWii:wii.boolValue saved:YES]); }];
    XCTAssertEqual([loads tableView:loads.tableView numberOfRowsInSection:0], 10);
    for (NSNumber* unavailableRow in @[@0, @8]) {
      NSIndexPath* row = [NSIndexPath indexPathForRow:unavailableRow.integerValue inSection:0];
      UITableViewCell* cell = [loads tableView:loads.tableView cellForRowAtIndexPath:row];
      XCTAssertTrue((cell.accessibilityTraits & UIAccessibilityTraitNotEnabled) != 0,
                    @"Empty and incompatible states must both be disabled");
      [loads tableView:loads.tableView didSelectRowAtIndexPath:row];
    }
    XCTAssertEqual(loads.confirmationCount, 0);
    XCTAssertEqual(operationCount, 1);
    UITableViewCell* loadable = [loads tableView:loads.tableView cellForRowAtIndexPath:lastRow];
    XCTAssertFalse((loadable.accessibilityTraits & UIAccessibilityTraitNotEnabled) != 0);
    expectedLoad = YES;
    [loads tableView:loads.tableView didSelectRowAtIndexPath:lastRow];
    XCTAssertEqual(loads.confirmationCount, 1);
    XCTAssertEqual(operationCount, 2, @"The load page must reach the native load callback");
    XCTAssertFalse(navigation.view.userInteractionEnabled);
    [loads tableView:loads.tableView didSelectRowAtIndexPath:lastRow];
    [loads resumePressed];
    XCTAssertEqual(operationCount, 2);
    XCTAssertEqual(resumeCount, 0);
    XCTAssertNotNil(finishOperation);
    void (^loadCompletion)(BOOL) = finishOperation;
    finishOperation = nil;
    [self completeOnNextMainTurn:^{ loadCompletion(YES); }];
    XCTAssertTrue(navigation.view.userInteractionEnabled);
    XCTAssertEqualObjects(loads.lastStateMessage, @"stateLoaded");
    XCTAssertNotNil(finishRead);
    readCompletion = finishRead;
    finishRead = nil;
    [self completeOnNextMainTurn:^{ readCompletion([self stateSnapshotForWii:wii.boolValue saved:YES]); }];
    [loads resumePressed];
    XCTAssertEqual(resumeCount, 1);
  }
}

- (void)testFailedSavestateOperationRestoresNavigationAndAllowsRetry {
  AutoConfirmSessionMenu* root = [AutoConfirmSessionMenu new];
  root.readStates = ^(void (^completion)(NSDictionary*)) {
    completion([self stateSnapshotForWii:NO saved:NO]);
  };
  __block void (^finishOperation)(BOOL) = nil;
  __block NSInteger operationCount = 0;
  root.performStateOperation = ^(NSInteger slot, BOOL load, void (^completion)(BOOL)) {
    XCTAssertEqual(slot, 10);
    XCTAssertFalse(load);
    operationCount++;
    finishOperation = [completion copy];
  };
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:root];
  [navigation loadViewIfNeeded];
  [root loadViewIfNeeded];
  AutoConfirmSessionMenu* saves = [self openStatePage:3 root:root navigation:navigation];
  NSIndexPath* lastRow = [NSIndexPath indexPathForRow:9 inSection:0];
  [saves tableView:saves.tableView didSelectRowAtIndexPath:lastRow];
  XCTAssertFalse(navigation.view.userInteractionEnabled);
  XCTAssertNotNil(finishOperation);
  void (^failedCompletion)(BOOL) = finishOperation;
  finishOperation = nil;
  [self completeOnNextMainTurn:^{ failedCompletion(NO); }];
  XCTAssertTrue(navigation.view.userInteractionEnabled);
  XCTAssertEqualObjects(saves.lastStateMessage, @"stateFailed");
  [saves tableView:saves.tableView didSelectRowAtIndexPath:lastRow];
  XCTAssertEqual(operationCount, 2, @"A failed write must not leave the menu locked");
  XCTAssertNotNil(finishOperation);
  void (^retryCompletion)(BOOL) = finishOperation;
  finishOperation = nil;
  [self completeOnNextMainTurn:^{ retryCompletion(NO); }];
  XCTAssertTrue(navigation.view.userInteractionEnabled);
}

- (void)testConsoleLanguageUsesSettingsSnapshotAndSavesChoice {
  DolphinSessionMenu* root = [DolphinSessionMenu new];
  root.wii = YES;
  __block NSDictionary* applied = nil;
  root.readSettings = ^(BOOL wii, NSInteger slot, void (^completion)(NSDictionary*)) {
    XCTAssertTrue(wii);
    XCTAssertEqual(slot, -1);
    completion(@{@"console": @{@"languages": @[
      @{@"name": @"English", @"value": @1, @"selected": @YES},
      @{@"name": @"Français", @"value": @3, @"selected": @NO}], @"restartNeeded": @NO}});
  };
  root.applySettings = ^(NSDictionary* request, void (^completion)(BOOL)) { applied = request; completion(YES); };
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:root];
  [root loadViewIfNeeded];
  [root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
  DolphinSessionMenu* console = (DolphinSessionMenu*)navigation.topViewController;
  [console loadViewIfNeeded];
  [console beginAppearanceTransition:YES animated:NO];
  [console endAppearanceTransition];
  XCTAssertEqual([console tableView:console.tableView numberOfRowsInSection:0], 2);
  [console tableView:console.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
  DolphinSessionMenu* choices = (DolphinSessionMenu*)navigation.topViewController;
  [choices loadViewIfNeeded];
  [choices tableView:choices.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
  XCTAssertEqualObjects(applied, (@{@"kind": @"language", @"wii": @YES, @"value": @3}));
}

- (NSArray<UIButton*>*)buttonsIn:(UIView*)view {
  NSMutableArray* buttons = [NSMutableArray array];
  if ([view isKindOfClass:UIButton.class]) [buttons addObject:view];
  for (UIView* subview in view.subviews) [buttons addObjectsFromArray:[self buttonsIn:subview]];
  return buttons;
}

- (void)testOriginalTouchLayoutsLoadAndCancelledPressReleasesInput {
  for (NSNumber* wii in @[@NO, @YES]) {
    DOLTouchOverlay* overlay = [[DOLTouchOverlay alloc] initWithWii:wii.boolValue];
    overlay.frame = CGRectMake(0, 0, 844, 390);
    [overlay layoutIfNeeded];
    NSArray<UIButton*>* buttons = [self buttonsIn:overlay];
    XCTAssertGreaterThan(buttons.count, 5u);
    UIButton* button = buttons.firstObject;
    XCTAssertGreaterThan([button imageForState:UIControlStateNormal].size.width, 0);
    [button sendActionsForControlEvents:UIControlEventTouchDown];
    NSArray* down = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
    XCTAssertEqualObjects(down[0], wii.boolValue ? @4 : @0);
    XCTAssertEqualObjects(down[2], @1);
    [button sendActionsForControlEvents:UIControlEventTouchCancel];
    NSArray* released = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
    XCTAssertEqualObjects(released[2], @0);
    if (wii.boolValue) {
      [overlay updateExtension:@"Classic"];
      [overlay layoutIfNeeded];
      XCTAssertGreaterThan([self buttonsIn:overlay].count, 8u);
    }
  }
}

- (void)testTouchButtonsKeepTheirLayoutWhilePressed {
  for (NSString* layout in @[@"GameCube", @"Nunchuk", @"Classic"]) {
    DOLTouchOverlay* overlay = [[DOLTouchOverlay alloc] initWithWii:![layout isEqualToString:@"GameCube"]];
    overlay.frame = CGRectMake(0, 0, 844, 390);
    [overlay updateExtension:layout];
    [overlay layoutIfNeeded];
    NSArray<UIButton*>* buttons = [self buttonsIn:overlay];
    NSMutableArray<NSValue*>* restingFrames = [NSMutableArray array];
    for (UIButton* button in buttons)
      [restingFrames addObject:[NSValue valueWithCGRect:[button convertRect:button.bounds toView:overlay]]];
    for (UIButton* pressed in buttons) {
      pressed.highlighted = YES;
      [pressed sendActionsForControlEvents:UIControlEventTouchDown];
      [overlay layoutIfNeeded];
      XCTAssertFalse(pressed.selected, @"A momentary control must not activate UIKit selection styling");
      for (NSUInteger index = 0; index < buttons.count; ++index) {
        UIButton* button = buttons[index];
        XCTAssertTrue(CGRectEqualToRect([button convertRect:button.bounds toView:overlay],
                                       restingFrames[index].CGRectValue), @"%@ pad moved during a press", layout);
      }
      pressed.highlighted = NO;
      [pressed sendActionsForControlEvents:UIControlEventTouchCancel];
      [overlay layoutIfNeeded];
    }
    UIView* pad = overlay.subviews.firstObject;
    [overlay updateExtension:layout];
    [overlay layoutIfNeeded];
    XCTAssertEqual(overlay.subviews.firstObject, pad, @"Unchanged extension polling must preserve the touch pad");
  }
}

- (void)testWiiPointerMovesOnTouchDownAndIgnoresReleaseCoordinates {
  DOLTouchOverlay* overlay = [[DOLTouchOverlay alloc] initWithWii:YES];
  overlay.frame = CGRectMake(0, 0, 844, 390);
  [overlay layoutIfNeeded];
  UIView* pad = overlay.subviews.firstObject;
  SimulatedPointerGesture* gesture = [SimulatedPointerGesture new];
  [NSUserDefaults.standardUserDefaults removeObjectForKey:@"lastTouch"];
  gesture.simulatedState = UIGestureRecognizerStateBegan;
  gesture.simulatedLocation = CGPointMake(522, 195);
  [pad handleLongPressWithGesture:gesture];
  NSArray* began = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
  XCTAssertNotNil(began, @"A new touch must position the pointer immediately");
  XCTAssertEqualObjects(began[0], @4);
  XCTAssertEqualObjects(began[1], @115);
  XCTAssertGreaterThan([began[2] doubleValue], 0.2);

  gesture.simulatedState = UIGestureRecognizerStateChanged;
  gesture.simulatedLocation = CGPointMake(650, 195);
  [pad handleLongPressWithGesture:gesture];
  NSArray* moved = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
  XCTAssertGreaterThan([moved[2] doubleValue], [began[2] doubleValue]);
  for (NSNumber* state in @[@(UIGestureRecognizerStateEnded), @(UIGestureRecognizerStateCancelled),
                            @(UIGestureRecognizerStateFailed)]) {
    gesture.simulatedState = (UIGestureRecognizerState)state.integerValue;
    gesture.simulatedLocation = CGPointMake(-5000, -5000);
    [pad handleLongPressWithGesture:gesture];
    XCTAssertEqualObjects([NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"], moved,
                          @"Lift-off and system gestures must not make the Wii pointer jump");
  }
}
@end
