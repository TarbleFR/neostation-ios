#import <XCTest/XCTest.h>

@interface DOLTouchOverlay : UIView
- (instancetype)initWithWii:(BOOL)wii;
- (void)updateExtension:(NSString*)name;
@end

@interface UIView (DOLPointerOwnershipTesting)
- (BOOL)acceptsPointerAt:(CGPoint)point hitView:(UIView*)view;
@end

@interface TouchOwnershipTests : XCTestCase
@end

@implementation TouchOwnershipTests
- (NSArray<UIView*>*)descendants:(UIView*)root {
  NSMutableArray* views = [NSMutableArray arrayWithObject:root];
  for (UIView* child in root.subviews) [views addObjectsFromArray:[self descendants:child]];
  return views;
}

- (DOLTouchOverlay*)overlay:(NSString*)layout {
  DOLTouchOverlay* overlay = [[DOLTouchOverlay alloc] initWithWii:![layout isEqualToString:@"GameCube"]];
  overlay.frame = CGRectMake(0, 0, 844, 390);
  [overlay updateExtension:layout];
  [overlay layoutIfNeeded];
  return overlay;
}

- (void)testEveryVirtualButtonIsCustomAndKeepsItsArtworkRectangle {
  for (NSString* layout in @[@"GameCube", @"Nunchuk", @"Classic"]) {
    DOLTouchOverlay* overlay = [self overlay:layout];
    NSUInteger count = 0;
    for (UIView* view in [self descendants:overlay]) {
      if (![view isKindOfClass:UIButton.class]) continue;
      UIButton* button = (UIButton*)view;
      count++;
      XCTAssertEqual(button.buttonType, UIButtonTypeCustom);
      XCTAssertNil(button.configuration);
      XCTAssertFalse(button.changesSelectionAsPrimaryAction);
      XCTAssertFalse(button.exclusiveTouch);
      UIImage* normal = [button imageForState:UIControlStateNormal];
      UIImage* pressed = [button imageForState:UIControlStateHighlighted];
      XCTAssertGreaterThan(normal.size.width, 0);
      XCTAssertTrue(CGSizeEqualToSize(normal.size, pressed.size));
      const CGRect frame = [button convertRect:button.bounds toView:overlay];
      const CGRect artwork = [button imageRectForContentRect:button.bounds];
      for (NSUInteger attempt = 0; attempt < 4; ++attempt) {
        button.highlighted = YES;
        [button sendActionsForControlEvents:UIControlEventTouchDown];
        [overlay layoutIfNeeded];
        XCTAssertTrue(CGRectEqualToRect(artwork, [button imageRectForContentRect:button.bounds]));
        XCTAssertTrue(CGRectEqualToRect(frame, [button convertRect:button.bounds toView:overlay]));
        button.highlighted = NO;
        [button sendActionsForControlEvents:UIControlEventTouchCancel];
      }
    }
    XCTAssertGreaterThan(count, 5u);
  }
}

- (void)testWiiButtonHitsCannotBecomePointerGestures {
  for (NSString* layout in @[@"Nunchuk", @"Classic"]) {
    DOLTouchOverlay* overlay = [self overlay:layout];
    UIView* pad = overlay.subviews.firstObject;
    NSUInteger count = 0;
    for (UIView* view in [self descendants:pad]) {
      if (![view isKindOfClass:UIButton.class]) continue;
      UIButton* button = (UIButton*)view;
      CGPoint centre = CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds));
      CGPoint padPoint = [button convertPoint:centre toView:pad];
      UIView* hit = [overlay hitTest:[button convertPoint:centre toView:overlay] withEvent:nil];
      XCTAssertTrue(hit == button || [hit isDescendantOfView:button], @"%@ button artwork must hit its own control", layout);
      XCTAssertFalse([pad acceptsPointerAt:padPoint hitView:hit]);
      [button sendActionsForControlEvents:UIControlEventTouchDown];
      NSArray* event = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
      XCTAssertEqualObjects(event[0], @4, @"Wii uses its own touchscreen port");
      XCTAssertEqualObjects(event[2], @1);
      [button sendActionsForControlEvents:UIControlEventTouchCancel];
      NSArray* released = [NSUserDefaults.standardUserDefaults arrayForKey:@"lastTouch"];
      XCTAssertEqualObjects(released[0], event[0]);
      XCTAssertEqualObjects(released[1], event[1]);
      XCTAssertEqualObjects(released[2], @0);
      count++;
    }
    XCTAssertGreaterThan(count, 5u);
  }
}

- (void)testWiiPointerAcceptsBlankSurfaceButNotControllerRegions {
  DOLTouchOverlay* overlay = [self overlay:@"Nunchuk"];
  UIView* pad = overlay.subviews.firstObject;
  UIView* surface = pad.subviews.firstObject;
  XCTAssertTrue([pad acceptsPointerAt:CGPointMake(422, 30) hitView:surface]);
  XCTAssertFalse([pad acceptsPointerAt:CGPointMake(-10, -10) hitView:surface]);
  NSUInteger sticks = 0;
  for (UIView* view in [self descendants:pad]) {
    const BOOL isStick = [NSStringFromClass(view.class) hasSuffix:@"TCJoystick"];
    const BOOL isDPad = [NSStringFromClass(view.class) hasSuffix:@"TCDirectionalPad"];
    if (!isStick && !isDPad) continue;
    CGPoint centre = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds)) toView:pad];
    XCTAssertFalse([pad acceptsPointerAt:centre hitView:view]);
    if (isStick) {
      UIPanGestureRecognizer* gesture = [UIPanGestureRecognizer new];
      [view addGestureRecognizer:gesture];
      id<UIGestureRecognizerDelegate> delegate = (id<UIGestureRecognizerDelegate>)pad;
      XCTAssertTrue([delegate gestureRecognizer:[UILongPressGestureRecognizer new]
          shouldRecognizeSimultaneouslyWithGestureRecognizer:gesture]);
      [view removeGestureRecognizer:gesture];
      sticks++;
    }
  }
  XCTAssertGreaterThan(sticks, 0u);
}
@end
