#!/usr/bin/env python3
"""Regression checks for full-theme home navigation and chrome."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
VIEW = (ROOT / "lib/screens/full_theme/full_theme_systems_view.dart").read_text()
APP = (ROOT / "lib/screens/app_screen.dart").read_text()


# The full theme shares AppScreen's already-established controller listener.
# Creating a second gamepad layer here previously left the themed home inert on
# iOS while the standard systems menu continued to work.
for token in (
    "static bool navigateLeft()",
    "static bool navigateRight()",
    "static bool navigateUp()",
    "static bool navigateDown()",
    "static Future<void> selectCurrent()",
    "FullThemeSystemsView.navigateLeft()",
    "FullThemeSystemsView.navigateRight()",
    "FullThemeSystemsView.navigateUp()",
    "FullThemeSystemsView.navigateDown()",
    "await FullThemeSystemsView.selectCurrent()",
):
    assert token in VIEW or token in APP, token

assert "GamepadNavigation _gamepadNav" not in VIEW
assert "GamepadNavigationManager.pushLayer" not in VIEW

# Touch users can swipe between systems and open the focused card with one tap.
assert "onHorizontalDragEnd:" in VIEW
assert "_move(velocity < 0 ? 1 : -1)" in VIEW
assert "if (isSelected)" in VIEW
assert "_openSelected();" in VIEW
assert "onDoubleTap:" not in VIEW

# NeoStation's global header already displays the clock. The theme must not
# render a second clock or its package name beneath the LB/RB bar.
assert "Timer.periodic" not in VIEW
assert "DateTime _now" not in VIEW
assert "Widget _topBar()" not in VIEW
assert "widget.theme.name.toUpperCase()" not in VIEW

print("Full-theme navigation/chrome contract: OK")
