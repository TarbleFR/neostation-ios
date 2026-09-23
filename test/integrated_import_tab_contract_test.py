#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[1]
screen = (root / "lib/screens/game_screen/my_games_list.dart").read_text()
card = (root / "lib/screens/game_screen/game_details_card/game_details_card_list.dart").read_text()
header = (root / "lib/screens/game_screen/game_details_card/widgets/game_details_tabs_header.dart").read_text()
dolphin = (root / "lib/widgets/dolphin_internal_playlist_actions.dart").read_text()
rpcs3 = (root / "lib/widgets/rpcs3_internal_playlist_actions.dart").read_text()

assert "final Widget? importAction" in card
assert "trailingAction: widget.importAction" in card
assert "final double actionWidth = trailingActionWidth ?? tabWidth" in header
assert "SizedBox(width: actionWidth, child: trailingAction)" in header
assert "_buildEmbeddedDolphinImportAction" in screen
assert "_buildEmbeddedRpcs3ImportAction" in screen
assert screen.count("embedded: true") >= 2
assert "if (widget.embedded) return button" in dolphin
assert "if (widget.embedded) return button" in rpcs3
assert "Overlay.of(context, rootOverlay: true)" in rpcs3
assert "_rpcs3FirmwareReady &&" in screen
print("Integrated import tab contract: OK")
