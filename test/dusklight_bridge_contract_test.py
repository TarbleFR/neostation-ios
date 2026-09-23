#!/usr/bin/env python3
"""Lock the embedded Dusklight host/Core ownership boundary."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
podspec = (ROOT / "packages/dusklight_internal_bridge/ios/dusklight_internal_bridge.podspec").read_text()
plugin = (ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightInternalBridgePlugin.mm").read_text()
abi = (ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightCoreABI.h").read_text()
loader = (ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightCoreLoader.h").read_text()
pins = json.loads((ROOT / "build-utils/dusklight/source.json").read_text())

assert "vendored_frameworks" not in podspec
assert "preserve_paths" in podspec
assert "NeoDusklightLoadCore(path.fileSystemRepresentation)" in plugin
assert "dlopen(path, RTLD_NOW | RTLD_LOCAL)" in loader
assert "isExecutableFileAtPath" not in plugin
assert "loaded.filePresent" in plugin and '@"buildNumber"' in plugin
assert "DUSKLIGHT_CORE_NOT_READY" in plugin
assert 'dlsym(_coreHandle, "NeoDusklight_GetAPI")' in plugin
for member in ("initialize", "start", "stop", "is_running", "set_event_callback", "session_state", "set_ui_text"):
    assert member in abi, member
assert pins["commit"] == "ad979d3dae092d0f5cbdaf49eabca7b4f1db4838"
assert pins["submodules"]["aurora"] == "d0933b745abe0eb9815bedcea8047575da18698d"
assert set(pins["supported_disc_ids"]) == {
    "GZ2E01", "GZ2J01", "GZ2P01", "RZDE01", "RZDJ01", "RZDP01"
}
assert "NEO_DUSKLIGHT_ABI_VERSION 3u" in abi
assert "NEO_DUSKLIGHT_RUNNING" in plugin and '@"stage": @"first_frame"' in plugin
assert "DUSKLIGHT_FIRST_FRAME_TIMEOUT" in plugin
assert "DUSKLIGHT_RESTART_REQUIRED" in plugin
assert "dlclose(" not in plugin, "Objective-C method pointers must not outlive their native image"
assert "NEO_DUSKLIGHT_DIFFERENT_DISC" in plugin
assert "started <= 0" in plugin
print("PASS: pinned Dusklight ABI v3 waits for each session's native frame and carries translated controls")
