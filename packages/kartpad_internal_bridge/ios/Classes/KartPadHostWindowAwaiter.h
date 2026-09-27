#pragma once
#import <UIKit/UIKit.h>

// A foreground transition is not a missing host. Keep the launch pending until
// UIKit can supply the validated window; never start SDL in an inactive scene.
@interface NeoKartPadHostWindowAwaiter : NSObject
- (instancetype)initWithSelection:(UIWindow* (^)(void))selection
                       completion:(void (^)(UIWindow*))completion;
- (void)start;
- (void)cancel;
@end
