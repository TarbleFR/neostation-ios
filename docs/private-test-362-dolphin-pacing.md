# Private Build 362 — Dolphin 120 Hz and stutter investigation

No GitHub release is created. Release 0.0.1 and the private Build 361 remain unchanged.
Native emulator and JIT binaries are retained; changes are confined to Dolphin's
host presentation settings, display hints, input-refresh scheduling and diagnostics.

## Defaults and comparison

This test requests 120 Hz on a compatible attached display, falling back to 60 Hz
when limited by hardware, Low Power Mode or serious thermal conditions. iOS still
arbitrates the actual display rate. No emulation speed, CPU clock or frame generation
is changed. MTKView stays paused; the new CADisplayLink does not draw or acquire
Metal drawables. It requests timing and measures callback cadence only.

Graphics > Display & smoothness exposes Automatic / 60 / 120 Hz, and three rendering
profiles: Original, Metal, Metal + hybrid shaders. The default candidate profile is
Metal + hybrid. Hybrid may take longer to compile initially and increase GPU load.
Switch to Metal alone to compare. Rendering profiles take effect only after quitting
the game and launching again, not through the emulated console's restart command.
Display-rate preference changes apply immediately. All visible strings cover 12 locales.

## Evidence versus hypotheses

The pinned Dolphin source defaults to synchronous shader compilation. NeoStation
already enables the shader cache and precompiles known shaders; previously unseen
pipelines remain a plausible cause of stalls. This trial requests enum value 2,
AsynchronousUberShaders, not skip-drawing mode.

The pinned Metal backend selects command-buffer presentDrawable with
MTLUsePresentDrawable=1. Upstream comments note a frame-pacing advantage compared
with presentation in an addScheduledHandler callback. The candidate requests that
existing path independently of the VSync setting; it does not call macOS-only APIs.

The original 500 ms monitor calls refresh_controllers even with no device change.
That crosses Dolphin's host queue and takes the emulated-controller state lock to
inspect the Wii extension, also during GameCube games. The candidate refreshes on
startup and actual controller/keyboard/configuration changes instead. Core input
sampling is unchanged. This removes avoidable periodic lock traffic; it is not
proof that these locks caused the reported stutters.

No trace from the affected device establishes one unique cause. These changes need
same-scene device comparison. PAL 50 FPS does not divide evenly into 120 Hz; no region
conversion, 120-FPS cheat, clock overdrive or frame skipping is applied.

## Rollback

Only MTLUsePresentDrawable and ShaderCompilationMode are staged in GFX.ini and
local GameINI files for the selected GameID. A recovery journal preserves prior
values. After normal native shutdown those values are restored, while manual cheats
and unrelated settings edited during the session are retained. A following Build
362 launch recovers an interrupted journal before staging a new trial.

Restore Build 361 behavior, then quit and relaunch, compares the original rendering
and polling behavior inside this build. Quit Dolphin normally before installing the
old IPA. If iOS killed the process, reopen Build 362 first to recover its journal.
Shader caches are not deleted on rollback. Original/hybrid-off startup also temporarily
seeds any absent GFX keys with their upstream defaults: BaseConfigLoader only updates
present keys on Config::Load and otherwise retains values in a warm process. These
default keys are removed again after shutdown if they were originally absent.

## Diagnostics and tests

The buffer holds at most 240 passive samples (2 Hz, about two minutes) in memory:
emulator FPS/VPS/speed and frame-time aggregates, controller-refresh duration,
thermal state and display-link timing. Export from Display & smoothness after a
stutter. Callback frequency is not physical panel scanout or game FPS, and 2-Hz
sampling is not an exhaustive per-frame profiler. No video/GPU readback or per-frame
file writing is added.

Validation covers iOS arm64 compilation, actual UIKit menus/display-link lifetime,
120/60-Hz hardware/power/thermal cases, bounded diagnostics, real-file rollback and
interrupted-launch recovery, existing cheats/media tests, pinned enum/config/Metal
bindings and final IPA contents. Passing those tests does not prove smooth gameplay
on a physical iPhone or iPad.

## Primary references

https://developer.apple.com/documentation/quartzcore/optimizing-iphone-and-ipad-apps-to-support-promotion-displays
https://dolphin-emu.org/blog/2017/07/30/ubershaders/
https://github.com/OatmealDome/dolphin-ios/blob/7cac54161659421ed95c2cd1c0b0746539a4cd38/Source/Core/VideoBackends/Metal/MTLGfx.mm
https://github.com/OatmealDome/dolphin-ios/blob/7cac54161659421ed95c2cd1c0b0746539a4cd38/Source/Core/VideoCommon/VideoConfig.h
