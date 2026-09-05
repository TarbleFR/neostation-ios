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
  XCTAssertEqual([menu.tableView numberOfRowsInSection:0], 6);
  for (NSInteger row = 0; row < 6; ++row)
    XCTAssertNotNil([menu tableView:menu.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]]);
}

- (void)testSavestateSlotsForBothConsolesDisableEmptyLoadAndRefreshAfterSave {
  for (NSNumber* wii in @[@NO, @YES]) {
    DolphinSessionMenu* root = [DolphinSessionMenu new];
    root.wii = wii.boolValue;
    root.labels = @{@"savestates": @"Save states", @"stateSlot": @"Slot {slot}",
        @"saveState": @"Save state", @"loadState": @"Load state", @"stateEmpty": @"Empty"};
    __block BOOL saved = NO;
    __block NSInteger operationCount = 0;
    __block void (^finishSave)(BOOL) = nil;
    root.readStates = ^(void (^completion)(NSDictionary*)) {
      NSMutableArray* slots = [NSMutableArray array];
      for (NSInteger slot = 1; slot <= 10; slot++)
        [slots addObject:@{@"slot": @(slot), @"exists": @(saved && slot == 10),
            @"loadable": @(saved && slot == 10), @"modified": @1700000000,
            @"filename": [NSString stringWithFormat:@"%@.s%02ld", wii.boolValue ? @"RMGE01" : @"GMSE01", (long)slot]}];
      completion(@{@"slots": slots});
    };
    root.performStateOperation = ^(NSInteger slot, BOOL load, void (^completion)(BOOL)) {
      operationCount++;
      XCTAssertEqual(slot, 10);
      XCTAssertFalse(load);
      finishSave = [completion copy];
    };
    UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:root];
    [navigation loadViewIfNeeded];
    [root loadViewIfNeeded];
    [root tableView:root.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
    DolphinSessionMenu* states = (DolphinSessionMenu*)navigation.topViewController;
    [states loadViewIfNeeded];
    [states beginAppearanceTransition:YES animated:NO]; [states endAppearanceTransition];
    XCTAssertEqual([states tableView:states.tableView numberOfRowsInSection:0], 10);
    UITableViewCell* last = [states tableView:states.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:9 inSection:0]];
    XCTAssertEqualObjects(last.textLabel.text, @"Slot 10");
    XCTAssertEqualObjects(last.detailTextLabel.text, @"Empty");
    [states tableView:states.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:9 inSection:0]];
    DolphinSessionMenu* actions = (DolphinSessionMenu*)navigation.topViewController;
    [actions loadViewIfNeeded];
    [actions beginAppearanceTransition:YES animated:NO]; [actions endAppearanceTransition];
    XCTAssertEqual([actions tableView:actions.tableView numberOfRowsInSection:0], 2);
    NSIndexPath* loadRow = [NSIndexPath indexPathForRow:1 inSection:0];
    UITableViewCell* loadCell = [actions tableView:actions.tableView cellForRowAtIndexPath:loadRow];
    XCTAssertEqualObjects(loadCell.textLabel.text, @"Load state");
    XCTAssertTrue((loadCell.accessibilityTraits & UIAccessibilityTraitNotEnabled) != 0);
    [actions tableView:actions.tableView didSelectRowAtIndexPath:loadRow];
    XCTAssertEqual(operationCount, 0);
    NSIndexPath* saveRow = [NSIndexPath indexPathForRow:0 inSection:0];
    [actions tableView:actions.tableView didSelectRowAtIndexPath:saveRow];
    XCTAssertEqual(operationCount, 1);
    XCTAssertFalse(navigation.view.userInteractionEnabled);
    // Repeated input cannot overlap the active native write.
    [actions tableView:actions.tableView didSelectRowAtIndexPath:saveRow];
    XCTAssertEqual(operationCount, 1);
    saved = YES;
    XCTAssertNotNil(finishSave);
    finishSave(YES);
    XCTAssertTrue(navigation.view.userInteractionEnabled);
    loadCell = [actions tableView:actions.tableView cellForRowAtIndexPath:loadRow];
    XCTAssertFalse((loadCell.accessibilityTraits & UIAccessibilityTraitNotEnabled) != 0);
    XCTAssertEqualObjects(loadCell.textLabel.text, @"Load state");
  }
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
