#pragma once

#import <UIKit/UIKit.h>

#include "KartPadHostWindowPolicy.h"

namespace neokartpad {

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
