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

KartPad accepts ISO and WBFS user images. ISO headers are validated directly;
WBFS is identified through NeoStation's embedded Dolphin DiscIO path and is
validated again by KartPad before guest execution. The canonical private
library is `Ports/KartPad/Games`, with separate `Saves`, `Config`,
`Mods`, `Logs` and `Metadata` directories.

The imported game is displayed and scraped as **Mario Kart Wii**, not as a
DuskLight/Twilight Princess title.

## Embedded Core architecture

The standalone KartPad application is not nested or launched from NeoStation.
NeoStation uses a lazy, host-owned Core boundary:

`GameLaunchService → KartPadInternalService → KartPadInternalBridge → KartPadCore.framework`

The bridge exposes NeoStation ABI v1 and validates the runtime identity
`kartpad_rmcp01_full_game_v1` before launch. KartPadCore is loaded with
`dlopen(..., RTLD_LOCAL)`; no NeoStation host image has a startup dyld
dependency on the Core.

UIKit application ownership remains with NeoStation. The maintained KartPad iOS
runtime is patched into framework mode rather than using its standalone
`UIApplicationMain` entry point. The existing Metal renderer, SunPad touch
controls, physical-controller handling and KartPad settings overlay remain owned
by KartPad's runtime.

The in-game return action is supplied by NeoStation in all twelve supported
languages. A normal **Return to NeoStation** suspends the guest at KartPad's
event boundary, releases its foreground UI/audio ownership and preserves the
same runtime for a subsequent resume. The native session state regression gate
exercises 100 consecutive return/resume cycles.

Fatal runtime termination is a separate terminal state and is never treated as
a normal warm return.

## Source pins

- Upstream project: `chrissotraidis/kartpad` (GPL-3.0)
- KartPad source pin: `0d657f361ccf0a03c0b8f9ec97b2bd237e16a658`
- Maintained iOS runtime pin:
  `d0b8dec62a8c98dd45736a996ae18327ada8fe3f`
- NeoStation ABI: 1
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

## Current validation status

The KartPad Core gate validates:

- ABI v1 and lazy loader contract;
- native retained-session state;
- Objective-C++ host syntax against iphoneos;
- the exact pinned upstream KartPad and iOS runtime revisions;
- application of the NeoStation framework patch to those real upstream sources;
- localized Return-to-NeoStation bridge;
- physical-iOS builder/packaging tools.

The Flutter/Ports gate validates:

- the shared Import menu;
- isolated DuskLight and KartPad libraries;
- ISO/WBFS import ownership;
- per-port ScreenScraper identity;
- twelve-language KartPad user messages;
- KartPad launch routing and native session monitoring;
- immediate Ports refresh after deletion.

## Remaining acceptance step

The architecture and NeoStation-side implementation are prepared. A **real**
KartPadCore artifact still needs to be built from an authorized RMCP01
translation graph, embedded into a post-322 experimental IPA, and tested on a
physical iPhone/iPad for first frame, controls, audio, return, resume and
relaunch. Build 322 remains the rollback baseline until that device acceptance
is complete.

A full NeoStation IPA is intentionally not produced from host/UI-only KartPad commits. The full candidate build is reserved for a validated, real KartPadCore artifact so Build 322 is not repackaged under a misleading candidate state.
