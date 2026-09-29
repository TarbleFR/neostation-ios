# NeoStation iOS 0.0.1 — Source and Binary Identity Manifest

This manifest documents the **already-published** GitHub release `0.0.1`.
It does not replace, re-sign, rebuild or modify the published IPA.

## Published binary identity

- Release tag: `0.0.1`
- Release title: `NeoStation iOS 0.0.1`
- Asset name: `NeoStation.ipa`
- Validated internal build: **Build 350**
- Packaging source commit: `5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0`
- Successful workflow run: `36323843067`
- Workflow artifact ID: `10932894067`
- Original artifact name: `NeoStation-iOS-Build-350-KartPad-Relaunch-Candidate`
- IPA size: `143538718` bytes
- IPA SHA-256: `e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46`

The GitHub release asset must remain byte-for-byte unchanged unless a future
release is intentionally published under a different version/tag.

## NeoStation host source

Exact source tree used to package Build 350:

https://github.com/TarbleFR/neostation-ios/tree/5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0

The repository contains NeoStation integration patches, build scripts, bridge
code and source-pinning manifests used to construct the native components.

## Embedded Dolphin / DolphiniOS

- Repository: https://github.com/OatmealDome/dolphin-ios
- Revision: `7cac54161659421ed95c2cd1c0b0746539a4cd38`
- Source: https://github.com/OatmealDome/dolphin-ios/tree/7cac54161659421ed95c2cd1c0b0746539a4cd38
- License notice: most original Dolphin code is GPL-2.0-or-later; per-file SPDX
  notices and the upstream `LICENSES/` directory remain authoritative.
- NeoStation integration source includes
  `build-utils/patch_dolphin_internal_core_v2.py` and
  `packages/dolphin_internal_bridge/`.

## Embedded RPCS3

- Repository used by the canonical materializer: https://github.com/XITRIX/rpcs3
- Revision: `22f1152783cef1f7e04af7b1c895173e28fd5b03`
- Source: https://github.com/XITRIX/rpcs3/tree/22f1152783cef1f7e04af7b1c895173e28fd5b03
- Canonical manifest: `build-utils/rpcs3/canonical-source.json`
- Canonical NeoStation delta: `build-utils/rpcs3/embedded-core.patch`
- License in that exact source revision: GNU GPL version 2; the upstream README
  states most files are GPL-2.0-only, with some files licensed differently.

NeoStation does not claim to relicense RPCS3.

## Embedded ARMSX2 / PCSX2

- Repository: https://github.com/ARMSX2/ARMSX2
- Revision: `8b5fad23dc290660aa394e75b0fd23e31099eaec`
- Source: https://github.com/ARMSX2/ARMSX2/tree/8b5fad23dc290660aa394e75b0fd23e31099eaec
- NeoStation pin: `build-utils/armsx2/source.json`
- Upstream includes `COPYING.GPLv3` and PCSX2-derived material with its own
  copyright/license history.

## Embedded Dusklight

- Repository: https://github.com/TwilitRealm/dusklight
- Revision: `ad979d3dae092d0f5cbdaf49eabca7b4f1db4838`
- Source: https://github.com/TwilitRealm/dusklight/tree/ad979d3dae092d0f5cbdaf49eabca7b4f1db4838
- Root license: CC0-1.0
- Aurora revision: `d0933b745abe0eb9815bedcea8047575da18698d`
- Borealis revision: `0bdba6c50a46409c4862474c72b4a3a631fbe0ec`
- SDL revision: `8e37db5e797b6167f3a00d697d816a684bd259c7` (SDL 3.4.10)
- NeoStation pin: `build-utils/dusklight/source.json`

## Embedded KartPad / WiiCompiled runtime

NeoStation pin: `build-utils/kartpad/source.json`

Recorded identities for Build 350:

- KartPad repository: https://github.com/chrissotraidis/kartpad
- Release: `v0.5.1-experimental.1`
- Release tag commit: `0d657f361ccf0a03c0b8f9ec97b2bd237e16a658`
- Compiled source identity: `67c7e2f942c1226af149e6a9cc571f647528e25e`
- iOS runtime commit: `d0b8dec62a8c98dd45736a996ae18327ada8fe3f`
- Upstream source archive SHA-256:
  `3a7f14e76d289efb398c1f42b3817e9eacd828cceef4d40d185663743c916360`
- Reference unsigned IPA SHA-256:
  `1474809c8e14447c159c30902aaf66b022db89d28a3181d69acfac3467508f58`
- Dawn archive: `dawn-ios-arm64-v20260603.191052.tar.gz`
- Dawn SHA-256:
  `a361fcca75929fa5c766cfcde979c010a6da7d805e5db8e15c75e73fd8260e78`

KartPad's pinned source metadata records this limitation:

> The upstream source delivery intentionally excludes generated game
> translation/profile inputs. A full KartPadCore must be built from an
> authorized RMCP01 translation graph.

That limitation is important. This manifest must not be presented as a claim
that every piece required to satisfy any applicable Corresponding Source
obligation for the translated runtime is publicly available.

KartPad's `RIGHTS_AND_LICENSES.md` also explains that its GPL software license
does not grant rights in Nintendo-owned game content or automatically clear
rights in generated translated game logic.

## StikJIT

- Project: https://github.com/StikDebug/StikJIT
- Version used by NeoStation: `1.5.0`
- Source: https://github.com/StikDebug/StikJIT/tree/1.5.0
- License: Mozilla Public License 2.0

## External integrations

RetroArch, MeloNX and LocalDevVPN are separate applications when used. They are
not embedded merely because NeoStation can interoperate with them.

## What this manifest does and does not mean

This file provides reproducible identity and source-location information. It is
not a legal opinion and does not itself cure a missing source or license
obligation.

For redistribution, preserve:

- all applicable license texts and notices;
- copyright and attribution notices;
- the exact NeoStation modifications/build scripts;
- access to source required by the applicable licenses;
- any installation information required by an applicable license.

See `docs/LEGAL_AND_CREDITS.md` and `NOTICE.md` for the complete attribution
record.
