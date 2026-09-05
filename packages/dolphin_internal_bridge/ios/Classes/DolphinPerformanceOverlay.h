// SPDX-License-Identifier: GPL-2.0-or-later
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Passive display of Dolphin core samples. All methods run on the main thread.
/// The owner starts/stops sampling when showing/hiding this view; no internal timer.
@interface DolphinPerformanceOverlay : UIView
- (instancetype)initWithLabels:(NSDictionary<NSString*, NSString*>*)labels;
- (void)appendSnapshot:(NSDictionary*)snapshot;
- (void)reset;
@end

NS_ASSUME_NONNULL_END
