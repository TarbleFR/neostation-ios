#!/usr/bin/env python3
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
script = (ROOT / "build-utils/kartpad/prepare_embedded_source.py").read_text()
core = (ROOT / "native/kartpad/core/NeoKartPadCore.mm").read_text()
state = (ROOT / "native/kartpad/core/SessionState.h").read_text()

for token in (
    "MKW_NEOSTATION_EMBEDDED_CORE",
    "NeoKartPadEmbeddedSupportPath",
    "NeoKartPadEmbeddedCachePath",
    "NeoKartPadEmbeddedGamePath",
    "NeoKartPadEmbeddedUIText",
    "aurora::webgpu::refresh_surface(true)",
    "aurora::webgpu::release_surface()",
    "aurora::wait_for_frame_worker()",
    "NeoKartPadEmbeddedPresentationResume",
    "NeoKartPadEmbeddedPresentationSuspend",
    "NeoKartPadUIText",
    "NeoKartPadEmbeddedShouldReturnToHost",
    "NeoKartPadEmbeddedSuspendGuestUntilResume",
    "NeoKartPadEmbeddedFramePresented",
    "KartPadMobileSetHostSuspended",
    "Return to NeoStation",
    "OUTPUT_NAME KartPadCore",
    "FRAMEWORK TRUE",
    "dispatch_sync_f(dispatch_get_main_queue()",
):
    assert token in script, token

for forbidden in ("pthread_cancel", "SDL_RunApp", "KartPadAppDelegate.mm"):
    assert forbidden not in core, forbidden

assert "std::condition_variable" in core
assert "guestCondition.wait" in core
assert "finishRetained()" in state
assert "NeoKartPadRuntimeRunGuest" in core
print("PASS: KartPad embedded patch preserves warm-return and UIKit ownership contracts")
