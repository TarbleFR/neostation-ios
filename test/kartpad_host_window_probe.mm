// Runs the production UIWindow picker inside a real foreground UIKit scene.
// No game data, Flutter binary or donor runtime is needed for this handoff.
#import <UIKit/UIKit.h>
#include "KartPadHostWindowSelection.h"

@interface ProbeFlutterController : UIViewController
@end
@implementation ProbeFlutterController
@end

static void SaveResult(BOOL success, NSString* reason) {
  NSString* documents = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  NSDictionary* result = @{@"success": @(success), @"reason": reason};
  NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
  [data writeToFile:[documents stringByAppendingPathComponent:@"host-window-probe.json"]
        atomically:YES];
}

@interface HostWindowProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* flutterWindow;
@property(nonatomic, strong) UIWindow* donorWindow;
@property(nonatomic, assign) NSUInteger attempts;
@end

@implementation HostWindowProbeSceneDelegate
- (void)scene:(UIScene*)scene
    willConnectToSession:(UISceneSession*)session
    options:(UISceneConnectionOptions*)options {
  UIWindowScene* windowScene = (UIWindowScene*)scene;
  self.flutterWindow = [[UIWindow alloc] initWithWindowScene:windowScene];
  self.flutterWindow.rootViewController = [ProbeFlutterController new];
  [self.flutterWindow makeKeyAndVisible];
  [self performSelector:@selector(checkHost) withObject:nil afterDelay:0.1];
}

- (void)checkHost {
  UIWindow* host = self.flutterWindow;
  if (host.windowScene.activationState != UISceneActivationStateForegroundActive) {
    if (++self.attempts < 100) {
      [self performSelector:@selector(checkHost) withObject:nil afterDelay:0.1];
    } else {
      SaveResult(NO, @"The simulator scene did not become foreground active.");
    }
    return;
  }

  if (neokartpad::FindFlutterHostWindow(nil, nil, ProbeFlutterController.class) != host) {
    SaveResult(NO, @"First launch did not discover the Flutter scene window.");
    return;
  }
  self.donorWindow = [[UIWindow alloc] initWithWindowScene:host.windowScene];
  self.donorWindow.rootViewController = [UIViewController new];
  [self.donorWindow makeKeyAndVisible];
  if (neokartpad::FindFlutterHostWindow(nil, host, ProbeFlutterController.class) != host) {
    SaveResult(NO, @"SDL key window displaced the Flutter host.");
    return;
  }

  // The previous selector loses the host as soon as UIKit replaces/detaches
  // the Flutter root, even though the same scene and host UIWindow survive.
  host.rootViewController = [UIViewController new];
  if (neokartpad::FindFlutterHostWindow(nil, nil, ProbeFlutterController.class)) {
    SaveResult(NO, @"The replacement root was mistaken for Flutter.");
    return;
  }
  [self.donorWindow setHidden:YES];
  [host makeKeyAndVisible];
  for (NSUInteger cycle = 0; cycle < 100; ++cycle) {
    if (neokartpad::FindFlutterHostWindow(nil, host, ProbeFlutterController.class) != host) {
      SaveResult(NO, @"Immediate relaunch lost the retained host window.");
      return;
    }
  }
  SaveResult(YES, @"UIKit first launch, SDL key handoff, root replacement and 100 relaunches passed.");
}
@end

@interface HostWindowProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation HostWindowProbeAppDelegate
@end

int main(int argc, char** argv) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil,
                             NSStringFromClass(HostWindowProbeAppDelegate.class));
  }
}
