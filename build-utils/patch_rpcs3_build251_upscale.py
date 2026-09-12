#!/usr/bin/env python3
"""Add NeoStation Build 251 RPCS3 in-game resolution-scale controls."""

from pathlib import Path


plugin_path = Path(
    "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm"
)
text = plugin_path.read_text()
marker = "NeoStation Build 251 resolution scale menu"

if marker not in text:
    method_anchor = "- (void)showGameMenu {\n"
    methods = r'''// NeoStation Build 251 resolution scale menu. RPCS3 exposes
// gpu.resolution_scale as a game/global integer from 25 to 800 in 25% steps.
// Keep the mobile menu intentionally bounded to useful iPhone/iPad presets.
- (NSArray<NSDictionary*>*)resolutionScaleChoices {
  return @[
    @{@"label": @"75% · Performance", @"value": @"75"},
    @{@"label": @"100% · Native", @"value": @"100"},
    @{@"label": @"125%", @"value": @"125"},
    @{@"label": @"150%", @"value": @"150"},
    @{@"label": @"175%", @"value": @"175"},
    @{@"label": @"200% · 2×", @"value": @"200"},
    @{@"label": @"250%", @"value": @"250"},
    @{@"label": @"300% · 3×", @"value": @"300"},
  ];
}

- (void)applyResolutionScale:(NSString*)value {
  NSString* titleId = [self.activeTitleId copy];
  if (!titleId.length || !value.length) return;
  dispatch_async(_runtimeQueue, ^{
    if (!self->_api.stop_emulation || !self->_api.set_game_setting ||
        !self->_api.boot_game) {
      [self showMessage:@"RPCS3" message:@"Resolution scaling is unavailable in this RPCS3 Core."];
      return;
    }

    // Match the already-audited language-setting transition: stop cleanly,
    // persist the per-game option, then reboot the same title. A per-game value
    // avoids changing the rendering cost of every other PS3 title.
    rpcs3_ios_status status = self->_api.stop_emulation();
    if (status == 0) {
      status = self->_api.set_game_setting(
          titleId.UTF8String, "gpu.resolution_scale", value.UTF8String);
    }
    if (status == 0) {
      status = self->_api.boot_game(titleId.UTF8String, NULL);
    }
    if (status != 0) {
      [self showMessage:@"RPCS3" message:[self lastError]];
      return;
    }
    RPCS3Diagnostic(@"resolution_scale",
                    [NSString stringWithFormat:@"%@%%", value]);
  });
}

- (void)showResolutionScaleMenu {
  RPCS3GameViewController* controller = self.gameController;
  if (!controller || !self.activeTitleId.length ||
      controller.presentedViewController) return;

  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"RPCS3 · Upscale"
                       message:@"Resolution scale · the game restarts to apply the selected value."
                preferredStyle:UIAlertControllerStyleAlert];
  __weak Rpcs3InternalBridgePlugin* weakSelf = self;
  for (NSDictionary* choice in [self resolutionScaleChoices]) {
    NSString* label = choice[@"label"];
    NSString* value = choice[@"value"];
    [alert addAction:[UIAlertAction actionWithTitle:label
                                               style:UIAlertActionStyleDefault
                                             handler:^(__unused UIAlertAction* action) {
      [weakSelf applyResolutionScale:value];
    }]];
  }
  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"cancel"]
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];
  [controller presentViewController:alert animated:YES completion:nil];
}

'''
    if method_anchor not in text:
        raise SystemExit("RPCS3 game-menu method anchor drifted")
    text = text.replace(method_anchor, methods + method_anchor, 1)

    language_action = '''  [alert addAction:[UIAlertAction actionWithTitle:[self localized:@"language"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    afterMenuDismiss(^{ [weakSelf showLanguageMenu]; });
  }]];
'''
    upscale_action = language_action + '''  [alert addAction:[UIAlertAction actionWithTitle:@"Upscale" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* action) {
    afterMenuDismiss(^{ [weakSelf showResolutionScaleMenu]; });
  }]];
'''
    if language_action not in text:
        raise SystemExit("RPCS3 localized language-menu anchor drifted")
    text = text.replace(language_action, upscale_action, 1)

    plugin_path.write_text(text)

print("NeoStation Build 251 RPCS3 upscale menu patch applied")
