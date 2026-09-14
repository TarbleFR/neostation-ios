#!/usr/bin/env python3
"""Present RPCS3 in-game choices as modern anchored iOS sheets."""

from pathlib import Path

PLUGIN = Path("packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm")
text = PLUGIN.read_text()
marker = "NeoStation Build 260 modern in-game sheets"

if marker not in text:
    anchor = "- (void)showLanguageMenu {\n"
    helper = r'''// NeoStation Build 260 modern in-game sheets. Action sheets use the
// native compact bottom-sheet presentation on iPhone and remain safely anchored
// to the menu button on iPad.
- (void)presentModernMenu:(UIAlertController*)menu
                     from:(RPCS3GameViewController*)controller {
  UIPopoverPresentationController* popover = menu.popoverPresentationController;
  if (popover) {
    popover.sourceView = controller.menuButton;
    popover.sourceRect = controller.menuButton.bounds;
    popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
  }
  [controller presentViewController:menu animated:YES completion:nil];
}

'''
    if anchor not in text:
        raise SystemExit("RPCS3 language menu anchor drifted")
    text = text.replace(anchor, helper + anchor, 1)

    methods = [
        "- (void)showLanguageMenu {",
        "- (void)showResolutionScaleMenu {",
        "- (void)showStretchMenu {",
        "- (void)showSaveSavestateMenu {",
        "- (void)showLoadSavestateMenu {",
        "- (void)showGameMenu {",
    ]
    for start in methods:
        start_index = text.find(start)
        end_index = text.find("\n- (", start_index + len(start))
        if start_index < 0 or end_index < 0:
            raise SystemExit(f"RPCS3 menu method drifted: {start}")
        segment = text[start_index:end_index]
        if "UIAlertControllerStyleAlert" not in segment:
            raise SystemExit(f"RPCS3 menu style drifted: {start}")
        segment = segment.replace(
            "UIAlertControllerStyleAlert", "UIAlertControllerStyleActionSheet"
        )
        segment = segment.replace(
            "[controller presentViewController:alert animated:YES completion:nil];",
            "[self presentModernMenu:alert from:controller];",
        )
        text = text[:start_index] + segment + text[end_index:]

    PLUGIN.write_text(text)

print("NeoStation Build 260 RPCS3 modern menu patch applied")
