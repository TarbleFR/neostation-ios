// SPDX-License-Identifier: GPL-2.0-or-later
#import <XCTest/XCTest.h>
#import "DolphinPerformanceOverlay.h"
#include <limits>

@interface PerformanceOverlayTests : XCTestCase
@end

@implementation PerformanceOverlayTests
- (NSDictionary*)snapshotAt:(double)timestamp frameTime:(double)frameTime width:(NSInteger)width {
  return @{@"timestampMs": @(timestamp), @"fps": @59.8, @"vps": @59.94,
      @"speedPercent": @99.8, @"frameTimeMs": @16.7,
      @"lastFrameTimeMs": @(frameTime), @"frameTimeStdMs": @1.4,
      @"renderWidth": @(width), @"renderHeight": @(width * 528 / 640)};
}

- (UILabel*)labelIn:(UIView*)view identifier:(NSString*)identifier {
  for (UIView* child in view.subviews)
    if ([child.accessibilityIdentifier isEqualToString:identifier]) return (UILabel*)child;
  XCTFail(@"Missing performance label %@", identifier);
  return nil;
}

- (void)testMeasuredSamplesBoundHistoryAndReportActualRenderSize {
  DolphinPerformanceOverlay* overlay = [[DolphinPerformanceOverlay alloc] initWithLabels:
      @{@"frameTime": @"Temps par image", @"resolution": @"Résolution interne"}];
  overlay.frame = CGRectMake(0, 0, 300, 170);
  [overlay layoutIfNeeded];
  XCTAssertFalse(overlay.userInteractionEnabled, @"Graph must not intercept game touch input");
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 0U);
  for (NSUInteger index = 0; index < 150; ++index)
    [overlay appendSnapshot:[self snapshotAt:100000 + index * 500
        frameTime:index == 145 ? 85 : 16.7 width:index >= 140 ? 1920 : 640]];
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 120U,
      @"Continuous play must keep a bounded history");
  XCTAssertEqualObjects([self labelIn:overlay identifier:@"dolphin.performance.resolution"].text,
      @"Résolution interne: 1920 × 1584");
  XCTAssertEqualObjects([self labelIn:overlay identifier:@"dolphin.performance.frameTime"].text,
      @"Temps par image: 16.7 ± 1.4 ms");
  XCTAssertTrue([overlay.accessibilityValue containsString:@"FPS 59.8"]);

  // Execute the real graph drawing with a measured 85 ms spike and scaled EFB.
  UIGraphicsImageRenderer* renderer = [[UIGraphicsImageRenderer alloc] initWithSize:overlay.bounds.size];
  UIImage* rendered = [renderer imageWithActions:^(UIGraphicsImageRendererContext* context) {
    [overlay.layer renderInContext:context.CGContext];
  }];
  XCTAssertTrue(rendered.CGImage != nullptr);
  XCTAssertEqual(CGImageGetWidth(rendered.CGImage), (size_t)(300 * rendered.scale));

  [overlay appendSnapshot:[self snapshotAt:300000 frameTime:20 width:1280]];
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 1U,
      @"Samples outside the last 60 seconds must be removed");
}

- (void)testHiddenInvalidOutOfOrderAndResetDoNotInventSamples {
  DolphinPerformanceOverlay* overlay = [[DolphinPerformanceOverlay alloc] initWithLabels:@{}];
  NSDictionary* valid = [self snapshotAt:100000 frameTime:16.7 width:640];
  [overlay appendSnapshot:valid];
  NSString* displayed = [overlay.accessibilityValue copy];
  [overlay appendSnapshot:valid];
  [overlay appendSnapshot:[self snapshotAt:99999 frameTime:50 width:1920]];
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 1U);
  for (NSString* key in @[@"fps", @"vps", @"speedPercent", @"frameTimeMs", @"lastFrameTimeMs",
                          @"frameTimeStdMs", @"timestampMs"]) {
    for (id invalid in @[[NSNull null], @"60", @(-1), @(std::numeric_limits<double>::quiet_NaN()),
                         @(std::numeric_limits<double>::infinity())]) {
      NSMutableDictionary* sample = [[self snapshotAt:101000 frameTime:25 width:1280] mutableCopy];
      sample[key] = invalid;
      [overlay appendSnapshot:sample];
    }
  }
  XCTAssertEqualObjects(overlay.accessibilityValue, displayed);
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 1U);

  overlay.hidden = YES;
  [overlay appendSnapshot:[self snapshotAt:102000 frameTime:25 width:1280]];
  XCTAssertEqualObjects(overlay.accessibilityValue, displayed);
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 1U);
  [overlay reset];
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 0U);
  XCTAssertFalse([overlay.accessibilityValue containsString:@"640"]);
  overlay.hidden = NO;
  NSMutableDictionary* startup = [valid mutableCopy];
  startup[@"fps"] = @0;
  startup[@"frameTimeMs"] = @0;
  startup[@"lastFrameTimeMs"] = @0;
  startup[@"renderWidth"] = @0;
  startup[@"renderHeight"] = @0;
  [overlay appendSnapshot:startup];
  XCTAssertEqual([[overlay valueForKey:@"sampleCount"] unsignedIntegerValue], 0U,
      @"Before the first frame there is no measured graph sample");
  XCTAssertTrue([[self labelIn:overlay identifier:@"dolphin.performance.resolution"].text hasSuffix:@"—"]);
}
@end
