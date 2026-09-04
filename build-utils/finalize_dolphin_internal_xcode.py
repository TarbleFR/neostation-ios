#!/usr/bin/env python3
"""Normalize and validate the generated Runner-side Dolphin registration."""

from pathlib import Path

root = Path(__file__).resolve().parents[1]
app_delegate = root / "ios" / "Runner" / "AppDelegate.swift"
text = app_delegate.read_text(encoding="utf-8")

text = text.replace(
    "\nGeneratedPluginRegistrant.register(with: self)\nNeoStationDolphinBridge.register(\n  with: self.registrar(forPlugin: \"NeoStationDolphinBridge\")\n)\n",
    "\n    GeneratedPluginRegistrant.register(with: self)\n"
    "    NeoStationDolphinBridge.register(\n"
    "      with: self.registrar(forPlugin: \"NeoStationDolphinBridge\")\n"
    "    )\n",
)
app_delegate.write_text(text, encoding="utf-8")

required = (
    "GeneratedPluginRegistrant.register(with: self)",
    "NeoStationDolphinBridge.register(",
    "self.registrar(forPlugin: \"NeoStationDolphinBridge\")",
)
for token in required:
    if text.count(token) != 1:
        raise SystemExit(f"Invalid AppDelegate registration token: {token}")

for line in text.splitlines():
    if "GeneratedPluginRegistrant.register" in line or "NeoStationDolphinBridge.register" in line:
        if not line.startswith("    "):
            raise SystemExit(f"AppDelegate registration is outside method scope: {line}")

print("Validated generated AppDelegate Dolphin registration.")
