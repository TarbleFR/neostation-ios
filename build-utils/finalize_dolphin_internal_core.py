#!/usr/bin/env python3
"""Apply compile-safety fixes to the generated Dolphin Objective-C++ bridge."""

from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: finalize_dolphin_internal_core.py <dolphin-checkout>")

source = Path(sys.argv[1]).resolve() / "Source/iOS/Library/NeoStationBridge.mm"
text = source.read_text(encoding="utf-8")

if "#include <algorithm>" not in text:
    text = text.replace(
        "#include <atomic>\n",
        "#include <algorithm>\n#include <atomic>\n#include <memory>\n",
        1,
    )

old = r'''  std::vector<std::string> paths{game_path};
  std::unique_ptr<BootParameters> boot =
      BootParameters::GenerateFromFile(paths, BootSessionData());
  if (!boot)
  {
    SetError(error, error_capacity, "Dolphin could not generate boot parameters for the image.");
    return 0;
  }

  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::iOS;
  wsi.render_surface = metal_layer;
  wsi.render_surface_scale = metal_scale;

  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::UndeclareAsHostThread();
  });

  __block bool booted = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    booted = BootManager::BootCore(system, std::move(boot), wsi);
  });
'''
new = r'''  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::iOS;
  wsi.render_surface = metal_layer;
  wsi.render_surface_scale = metal_scale;

  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::UndeclareAsHostThread();
  });

  const std::string boot_path = game_path;
  __block bool booted = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    std::vector<std::string> paths{boot_path};
    std::unique_ptr<BootParameters> boot =
        BootParameters::GenerateFromFile(paths, BootSessionData());
    if (boot)
      booted = BootManager::BootCore(system, std::move(boot), wsi);
  });
'''
if old not in text and new not in text:
    raise SystemExit("Unexpected generated NeoStationBridge.mm boot block")
text = text.replace(old, new, 1)
source.write_text(text, encoding="utf-8")
print("Finalized generated Dolphin Objective-C++ bridge.")
