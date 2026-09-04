#import <XCTest/XCTest.h>
#import "DolphinSessionMenu.h"

@interface DOLTouchOverlay : UIView
- (instancetype)initWithWii:(BOOL)wii;
- (void)updateExtension:(NSString*)name;
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
  XCTAssertEqual([menu.tableView numberOfRowsInSection:0], 5);
  for (NSInteger row = 0; row < 5; ++row)
    XCTAssertNotNil([menu tableView:menu.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]]);
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
@end
