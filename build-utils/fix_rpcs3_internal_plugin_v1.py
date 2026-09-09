#!/usr/bin/env python3
from pathlib import Path

path = Path('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm')
text = path.read_text()
old = '''    __block RPCS3GameViewController* controller = nil;
    dispatch_sync(dispatch_get_main_queue(), ^{
      UIViewController* root = RPCS3RootViewController();
      if (!root || root.view.window == nil) return;
      controller = [RPCS3GameViewController new];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      controller.closeHandler = ^{ [weakSelf stopAndDismiss:nil]; };
      [controller loadViewIfNeeded];
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
    });
    if (!controller || !controller.metalLayer.device) { result(@{@"success": @NO, @"message": @"Metal surface could not be created."}); return; }
    dispatch_async(_runtimeQueue, ^{
      CGSize size = controller.view.bounds.size;
      CGFloat scale = controller.view.window.screen.scale ?: UIScreen.mainScreen.scale;
'''
new = '''    __block RPCS3GameViewController* controller = nil;
    void (^presentController)(void) = ^{
      UIViewController* root = RPCS3RootViewController();
      if (!root || root.view.window == nil) return;
      controller = [RPCS3GameViewController new];
      __weak Rpcs3InternalBridgePlugin* weakSelf = self;
      controller.closeHandler = ^{ [weakSelf stopAndDismiss:nil]; };
      [controller loadViewIfNeeded];
      [root presentViewController:controller animated:NO completion:nil];
      self.gameController = controller;
    };
    if (NSThread.isMainThread) {
      presentController();
    } else {
      dispatch_sync(dispatch_get_main_queue(), presentController);
    }
    if (!controller || !controller.metalLayer.device) { result(@{@"success": @NO, @"message": @"Metal surface could not be created."}); return; }
    dispatch_async(_runtimeQueue, ^{
      CGSize size = controller.view.bounds.size;
      CGFloat scale = controller.view.window != nil
          ? controller.view.window.screen.scale
          : UIScreen.mainScreen.scale;
'''
count = text.count(old)
if count != 1:
    raise SystemExit(f'RPCS3 launch presentation block: expected one match, found {count}')
path.write_text(text.replace(old, new, 1))
