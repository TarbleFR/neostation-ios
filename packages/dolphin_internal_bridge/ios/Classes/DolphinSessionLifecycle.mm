#import "DolphinSessionLifecycle.h"

void DOLDismissSessionController(UIViewController* controller, dispatch_block_t completion) {
  NSCAssert(NSThread.isMainThread, @"Dolphin UI teardown must run on the main thread");
  if (!controller) { if (completion) completion(); return; }
  // UIKit may reject a second presentation/dismissal while one is in flight.
  // Finish that transition before removing the session chain. In particular,
  // an external stop can arrive while the settings panel is still appearing.
  for (UIViewController* node = controller; node; node = node.presentedViewController) {
    if (!node.isBeingPresented && !node.isBeingDismissed) continue;
    id<UIViewControllerTransitionCoordinator> coordinator = node.transitionCoordinator;
    if (coordinator && [coordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
      dispatch_async(dispatch_get_main_queue(), ^{ DOLDismissSessionController(controller, completion); });
    }]) return;
  }
  // Dismissing from the game while it presents settings only dismisses those
  // settings. Ask the frontend presenter to remove the entire session chain.
  UIViewController* presenter = controller.presentingViewController;
  if (presenter) [presenter dismissViewControllerAnimated:NO completion:completion];
  else if (controller.presentedViewController)
    [controller dismissViewControllerAnimated:NO completion:completion];
  else if (completion) completion();
}
