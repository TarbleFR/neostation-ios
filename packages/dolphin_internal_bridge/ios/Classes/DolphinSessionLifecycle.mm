#import "DolphinSessionLifecycle.h"

void DOLDismissSessionController(UIViewController* controller) {
  NSCAssert(NSThread.isMainThread, @"Dolphin UI teardown must run on the main thread");
  if (!controller) return;
  // Dismissing from the game while it presents settings only dismisses those
  // settings. Ask the frontend presenter to remove the entire session chain.
  UIViewController* presenter = controller.presentingViewController;
  if (presenter) [presenter dismissViewControllerAnimated:NO completion:nil];
  else [controller dismissViewControllerAnimated:NO completion:nil];
}
