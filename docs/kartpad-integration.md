# KartPad native port — NeoStation integration

## Stable baseline

NeoStation iOS **Build 322** remains the stable restoration point. All KartPad
work lives after that baseline on `experimental`; the Build 322 native cores
are not modified by the KartPad integration.

## User model

NeoStation does **not** ship Mario Kart Wii. The user imports their own supported
Mario Kart Wii PAL image (`RMCP01`, disc 0, revision 0) from the Ports playlist.

The Ports action is now:

`Import → DuskLight / Mario Kart Pad`

KartPad accepts ISO, WBFS and RVZ user images. ISO headers are validated
directly; WBFS and RVZ are identified through NeoStation's embedded Dolphin
DiscIO path. RVZ is then extracted transactionally during the Import action by
KartPad's own pinned DiscIO extractor, so the user never has to convert it to
ISO first. KartPad validates RMCP01 disc 0 revision 0 before committing the
prepared game data. The canonical private
library is `Ports/KartPad/Games`. Runtime state is mapped deliberately into
NeoStation's Files-visible layout: Wii NAND/save data lives in
`Ports/KartPad/Saves/NAND`, runtime configuration in
`Ports/KartPad/Config/Config.toml`, logs in `Ports/KartPad/Logs`, and Aurora
texture replacements under `Ports/KartPad/Mods/texture_replacements`.
`Metadata` remains reserved for NeoStation-side port metadata.

The imported game is displayed and scraped as **Mario Kart Wii**, not as a
DuskLight/Twilight Princess title.

## Embedded Core architecture

The standalone KartPad application is not nested or launched from NeoStation.
NeoStation uses a lazy, host-owned Core boundary:

`GameLaunchService → KartPadInternalService → KartPadInternalBridge → KartPadCore.framework`

The bridge exposes NeoStation ABI v2 and validates the runtime identity
`kartpad_rmcp01_full_game_v1` before launch. KartPadCore is loaded with
`dlopen(..., RTLD_LOCAL)`; no NeoStation host image has a startup dyld
dependency on the Core.

UIKit application ownership remains with NeoStation. The maintained KartPad iOS
runtime is patched into framework mode rather than using its standalone
`UIApplicationMain` entry point. The existing Metal renderer, SunPad touch
controls, physical-controller handling and KartPad settings overlay remain owned
by KartPad's runtime.

The in-game return action is supplied by NeoStation in all twelve supported
languages. Normal return and confirmed language restart request a cooperative
guest exit at the frame boundary. The host waits for the save/title transition,
AX worker, GPU frame worker and sockets, then lets RuntimeMain unwind its
fibers, mobile host, Aurora renderer and transcript workers. Only after that
return does the native session become reusable.

The ABI reports an explicit termination reason. A clean `userReturn` completes
the host session; `languageRestart` alone permits the bridge to create another
session on a later host turn. An unsuccessful shutdown remains a real failure,
regardless of the user's original intent. An unexpected native failure is not
proof that it is safe to launch again.

RuntimeMain is entered by the owned NSTimer scheduler in `SessionRunLoop.h`,
not by a block occupying the main dispatch queue throughout gameplay. The Apple
regression exercises this same scheduler and reproduces the previous queue
starvation as a negative control. Entry, window-poll and alert-retry timers are
invalidated at teardown; confirmation IDs remain monotonic between sessions.
Language/return menu actions and delayed settings work reject stale sessions.

This donor is not a completely unloadable runtime. Its Objective-C image,
GuestFlat address reservation, frozen translation registry and DVD host index
remain process-owned. Guest page tables are reset and the next RuntimeMain
reinitializes the guest backing sections and republishes the DVD globals.
Logs explicitly distinguish session teardown from retained process resources.
Do not describe this as proof that all runtime mappings are freed.

## Internal KartPad settings

The embedded donor host adds a NeoStation-owned **KartPad Settings** gear next
to **Return to NeoStation**. It uses KartPad/SunPad's canonical preferences
rather than introducing a second graphics configuration:

- Game language: English, German, French, Spanish, Italian or Dutch, matching
  the localization resources shipped by PAL RMCP01. The selection is persisted
  as Wii `IPL.LNG` in KartPad's private NAND so the game's own
  `SCGetLanguage()` sees it.
- Render resolution: 1x, 2x, 3x or 4x via `SunPadRenderScale`.
- Aspect ratio: original 4:3, fixed 16:9 or fill screen via
  `SunPadAspectRatioMode`.
- FPS counter via `SunPadShowFPSCounter`.

A game-language change is confirmed through the twelve-language NeoStation
catalog. Acceptance persists the selection and Wii SYSCONF, requests orderly
shutdown, then launches a new session with the selected language. Cancellation
keeps the existing selection. The PAL game supports six languages; that is
separate from NeoStation's twelve interface languages.

## Source pins

- Upstream project: `chrissotraidis/kartpad` (GPL-3.0)
- KartPad source pin: `0d657f361ccf0a03c0b8f9ec97b2bd237e16a658`
- Maintained iOS runtime pin:
  `d0b8dec62a8c98dd45736a996ae18327ada8fe3f`
- NeoStation ABI: 2
- Runtime identity: `kartpad_rmcp01_full_game_v1`
- Supported disc: Mario Kart Wii PAL `RMCP01`, disc 0, revision 0
- Expected translated functions: 29,637

The physical-iOS builder also pins the Dawn iphoneos archive by SHA-256 and
refuses a source/runtime/profile mismatch.

## Why the user import and the build-time graph are separate

KartPad is an **ahead-of-time translated port**. The user's ISO/WBFS supplies the
game data used by the installed runtime. The Core binary itself must already
contain the native translation graph generated from the supported RMCP01 code,
just as KartPad's own distributed application does.

Upstream intentionally excludes those generated C++ translation files from its
public source archive. NeoStation therefore does not fabricate them and does not
attempt to compile native code on the iPhone. The builder
`build-utils/kartpad/build_embedded_core.sh` accepts an authorized generated
RMCP01 graph, verifies the expected 29,637 functions and produces an
iphoneos/arm64 `KartPadCore.framework`.

This does **not** change the end-user flow: the installed NeoStation IPA still
contains no Mario Kart Wii disc image or extracted game-data tree; the user
imports their own game.

## Packaging and validation

NeoStation now contains:

- `build-utils/kartpad/build_embedded_core.sh` — physical-iOS Core builder.
- `build-utils/kartpad/validate_embedded_core.py` — Core identity/ABI validator.
- `build-utils/kartpad/embed_core.py` — controlled Runner.app embedder.
- `build-utils/validate_kartpad_ipa.py` — final IPA validator.

The IPA validator checks the exact Core hash, ABI export, iPhoneOS Mach-O
platform, packaged identity, lazy-load boundary and absence of a nested
`KartPad.app`.

## Validation scope

The regression gates execute the ARM64 language and frame-return bridges,
profile/DVD reentry guards, guest language rollback, 1,000 session transitions
and stale confirmation rejection. The Apple test reproduces the main-queue
starvation and verifies the actual production timer scheduler. A separate
UIKit probe checks selected native ABI and registry operations. These tests do
not run a complete Mario Kart Wii gameplay session.

The donor build gates the exact binary, host sources and production scheduler;
the full IPA build checks the embedded Core identity and runtime bridge bytes.
No other emulator Core is rebuilt for this change.

Physical-device acceptance is still required: French → English → French with
confirmed restarts, at least three manual launch/return cycles followed by
repetition, continued NeoStation responsiveness, and resource counts after each
shutdown. An IPA build, native state-machine loop or UIKit ABI probe is not
acceptance evidence for those end-to-end scenarios.
