#!/usr/bin/env python3
"""Normalize and validate the generated Runner-side Dolphin registration."""

from pathlib import Path

root = Path(__file__).resolve().parents[1]
app_delegate = root / "ios" / "Runner" / "AppDelegate.swift"
text = app_delegate.read_text(encoding="utf-8")

# Older Flutter templates register plugins directly on AppDelegate. Keep the
# formatting repair for those generated projects, but do not rewrite the newer
# FlutterImplicitEngineDelegate form.
text = text.replace(
    "\nGeneratedPluginRegistrant.register(with: self)\nNeoStationDolphinBridge.register(\n  with: self.registrar(forPlugin: \"NeoStationDolphinBridge\")\n)\n",
    "\n    GeneratedPluginRegistrant.register(with: self)\n"
    "    NeoStationDolphinBridge.register(\n"
    "      with: self.registrar(forPlugin: \"NeoStationDolphinBridge\")\n"
    "    )\n",
)
app_delegate.write_text(text, encoding="utf-8")

implicit_registration = (
    "GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)"
)
legacy_registration = "GeneratedPluginRegistrant.register(with: self)"

if text.count(implicit_registration) == 1:
    required = (
        implicit_registration,
        "engineBridge.pluginRegistry.registrar(",
        'forPlugin: "NeoStationDolphinBridge"',
        "NeoStationDolphinBridge.register(with: registrar)",
    )
    mode = "FlutterImplicitEngineDelegate"
elif text.count(legacy_registration) == 1:
    required = (
        legacy_registration,
        "NeoStationDolphinBridge.register(",
        'self.registrar(forPlugin: "NeoStationDolphinBridge")',
    )
    mode = "legacy AppDelegate"
else:
    raise SystemExit(
        "Invalid AppDelegate: exactly one supported GeneratedPluginRegistrant "
        "registration is required."
    )

for token in required:
    if text.count(token) != 1:
        raise SystemExit(f"Invalid AppDelegate registration token: {token}")

if text.count('forPlugin: "NeoStationDolphinBridge"') != 1:
    raise SystemExit("Dolphin Flutter registrar must be declared exactly once.")

for line in text.splitlines():
    if (
        "GeneratedPluginRegistrant.register" in line
        or "NeoStationDolphinBridge.register" in line
    ) and not line.startswith("    "):
        raise SystemExit(f"AppDelegate registration is outside method scope: {line}")

print(f"Validated generated AppDelegate Dolphin registration ({mode}).")
