#import "KartPadHostWindowAwaiter.h"

@implementation NeoKartPadHostWindowAwaiter {
  UIWindow* (^_selection)(void);
  void (^_completion)(UIWindow*);
  NSTimer* _timer;
  CFTimeInterval _activeSince;
}
- (instancetype)initWithSelection:(UIWindow* (^)(void))selection
                       completion:(void (^)(UIWindow*))completion {
  if ((self = [super init])) {
    _selection = [selection copy];
    _completion = [completion copy];
  }
  return self;
}
- (BOOL)check {
  if (!_completion) return YES;
  UIWindow* window = _selection ? _selection() : nil;
  if (!window) {
    // Background time must not consume the foreground recovery budget. On
    // return, activation can arrive after an already-overdue timer fires.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
      _activeSince = 0;
      return NO;
    }
    const CFTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (_activeSince == 0) _activeSince = now;
    if (now - _activeSince < 3.0) return NO;
  }
  void (^completion)(UIWindow*) = _completion;
  [self cancel];
  completion(window);
  return YES;
}
- (void)start {
  NSAssert(NSThread.isMainThread, @"Host presentation belongs to UIKit");
  if (_timer || !_completion) return;
  // A synchronous completion may release the caller's last reference to us.
  // Do not touch an ivar after check has completed.
  if ([self check]) return;
  __weak NeoKartPadHostWindowAwaiter* weakSelf = self;
  _timer = [NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) {
    [weakSelf check];
  }];
  [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}
- (void)cancel {
  [_timer invalidate];
  _timer = nil;
  _selection = nil;
  _completion = nil;
}
- (void)dealloc { [self cancel]; }
@end
