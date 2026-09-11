#import <UIKit/UIKit.h>

#include "Rpcs3CoreABI.h"

NS_ASSUME_NONNULL_BEGIN

// Owns all PS3 input while the embedded RPCS3 full-screen view is active.
// Physical GameController input is sent directly to the Core ABI. When no
// physical controller is connected, a native touch overlay is shown instead.
@interface RPCS3GameInputController : NSObject

- (instancetype)initWithHostView:(UIView*)hostView
                             api:(rpcs3_ios_api*)api NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (void)start;
- (void)stop;
- (void)layoutControlsInBounds:(CGRect)bounds safeAreaInsets:(UIEdgeInsets)insets;

@end

NS_ASSUME_NONNULL_END