#!/usr/bin/env python3
"""Bridge the legacy patch anchor to the current split game-list imports."""

from pathlib import Path
import sys

if len(sys.argv) != 2 or sys.argv[1] not in {"before", "after"}:
    raise SystemExit("usage: patch_dolphin_games_list_compat.py before|after")

root = Path(__file__).resolve().parents[1]
target = root / "lib/screens/game_screen/my_games_list.dart"
text = target.read_text(encoding="utf-8")
legacy = "import 'package:neostation/widgets/game_view_footer.dart';\n"
current = "import '../../widgets/game_view_mode_dropdown.dart';\n"
dolphin = "import 'package:neostation/widgets/dolphin_playlist_actions.dart';\n"

if sys.argv[1] == "before":
    if legacy not in text and dolphin not in text:
        if text.count(current) != 1:
            raise SystemExit("Current game-list import anchor is not unique")
        text = text.replace(current, legacy + current, 1)
        target.write_text(text, encoding="utf-8")
        print("Inserted temporary compatibility anchor for Dolphin playlist patch.")
else:
    if dolphin not in text:
        raise SystemExit("Dolphin playlist import was not materialized")
    if legacy in text:
        text = text.replace(legacy, "", 1)
        target.write_text(text, encoding="utf-8")
        print("Removed temporary compatibility import.")
