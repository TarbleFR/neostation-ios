// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Passive NeoStation overlay for RPCS3's lock-independent iOS performance API.
/// The owner samples only while this view is visible.
@interface RPCS3PerformanceOverlay : UIView
- (void)appendMetricsWithFPS:(double)fps
                         cpu:(double)cpu
                         gpu:(double)gpu
                  memoryUsed:(uint64_t)memoryUsed
                 memoryTotal:(uint64_t)memoryTotal
                 validFields:(uint32_t)validFields
                   timestamp:(double)timestampMs;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
