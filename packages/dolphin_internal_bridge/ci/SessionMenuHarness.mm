#import <UIKit/UIKit.h>

// The simulator exercises the actual UIKit/Swift controls without JIT or a ROM.
extern "C" void neostation_dolphin_touch_event(int32_t port, int32_t input, float value, int32_t axis) {
  [NSUserDefaults.standardUserDefaults setObject:@[@(port), @(input), @(value), @(axis)] forKey:@"lastTouch"];
}

@interface SessionHarnessDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation SessionHarnessDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  [self.window makeKeyAndVisible];
  return YES;
}
@end
int main(int argc, char** argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"SessionHarnessDelegate"); }
}
