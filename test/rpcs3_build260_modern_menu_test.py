#!/usr/bin/env python3
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else Path(__file__).resolve().parents[1]
plugin = (root / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm").read_text()

for token in [
    "NeoStation Build 260 modern in-game sheets",
    "presentModernMenu:",
    "UIAlertControllerStyleActionSheet",
    "popover.sourceView = controller.menuButton",
    "popover.sourceRect = controller.menuButton.bounds",
]:
    assert token in plugin, token

assert plugin.count("UIAlertControllerStyleActionSheet") >= 6
print("RPCS3 Build 260 modern in-game menu contract: OK")
