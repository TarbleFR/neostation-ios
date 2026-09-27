#pragma once

#import <UIKit/UIKit.h>

#include "KartPadHostWindowPolicy.h"

namespace neokartpad {

inline NSDictionary* DescribeHostWindow(UIWindow* window) {
  return @{@"address":@((uintptr_t)(__bridge void*)window),
           @"attached":@(window.windowScene != nil),
           @"hidden":@(window.hidden), @"alpha":@(window.alpha),
           @"key":@(window.isKeyWindow),
           @"sceneState":window.windowScene ? @(window.windowScene.activationState) : @99,
           @"root":window.rootViewController ? NSStringFromClass(window.rootViewController.class) : @"nil"};
}

inline NSString* DescribeFlutterHost(UIViewController* controller, UIWindow* retained) {
  NSMutableArray* windows = [NSMutableArray array];
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows)
      [windows addObject:DescribeHostWindow(window)];
  }
  NSDictionary* state = @{
      @"applicationState":@(UIApplication.sharedApplication.applicationState),
      @"runLoopMode":NSRunLoop.currentRunLoop.currentMode ?: @"none",
      @"registrarWindow":DescribeHostWindow(controller.viewIfLoaded.window),
      @"retainedWindow":DescribeHostWindow(retained), @"windows":windows};
  NSData* json = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
  return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
}

// Return the UIWindow itself: its identity survives transient changes to
// Flutter's view/controller hierarchy during SDL's window handoff.
inline UIWindow* FindFlutterHostWindow(UIViewController* flutterController,
                                      UIWindow* retainedWindow,
                                      Class flutterControllerClass) {
  NSMutableArray<UIWindow*>* windows = [NSMutableArray array];
  std::vector<HostWindowCandidate> candidates;
  auto appendWindow = [&](UIWindow* window) {
    if (!window || !window.windowScene) return;
    [windows addObject:window];
    candidates.push_back({true, true,
                          !window.hidden && window.alpha > 0.01,
                          window.windowScene.activationState ==
                              UISceneActivationStateForegroundActive,
                          static_cast<bool>(window.isKeyWindow)});
  };

  auto appendController = [&](UIViewController* controller) {
    UIView* view = controller.isViewLoaded ? controller.view : nil;
    appendWindow(view.window);
  };
  appendController(flutterController);
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class] ||
        scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow* window in ((UIWindowScene*)scene).windows) {
      UIViewController* root = window.rootViewController;
      if (![root isKindOfClass:flutterControllerClass] ||
          root == flutterController) continue;
      appendController(root);
    }
  }

  // When the registrar and scene scan cannot see Flutter's controller after
  // SDL teardown, reuse only the window validated on an earlier launch.
  appendWindow(retainedWindow);

  const int selected = SelectHostWindow(candidates);
  return selected < 0 ? nil : windows[static_cast<NSUInteger>(selected)];
}

}  // namespace neokartpad
