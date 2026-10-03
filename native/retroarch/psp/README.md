# Pinned PPSSPP libretro input for NeoStation

The supplied `2026-10-03_RetroArch.ipa` contains PPSSPP metadata but no PPSSPP
framework. This supplementary input adds the official libretro iOS ARM64 core;
it does not bundle a second application or rebuild the other emulators.

`ppsspp_libretro.dylib.zip` is the original official buildbot download, retained
in this repository so `latest` changing cannot silently alter or break a fresh
candidate checkout. Its SHA-256 is
`5dec365c3956b78d05085391d80761664064cd0377e8165dec5cc128f863e5dc`.
The unmodified dylib SHA-256 is
`52cec262640fb3eb1aea9521c3576cba827095f52878c2c673b1f6a352d4927a`.
The `_PPSSPP_GIT_VERSION` symbol points to `91a3405`, resolved against the
[official PPSSPP repository](https://github.com/hrydgard/ppsspp/commit/91a34056d036b22ee9ec1a656875fc780eff5efb).

The audit reads the actual Mach-O platform, architecture, dependency commands,
25 defined libretro ABI exports and source-version pointer. This is an ARM64
**iOS device** dylib (minimum iOS 12), with public OpenGLES/system dependencies.
It is not an iOS simulator or macOS binary. NeoStation still targets iOS 18+.

`pins.json` records the exact core, supplied IPA metadata and matching upstream
source/archive identities. The source archive supplies PPSSPP's own support
assets, including `compat.ini`, `ppge_atlas.zim`, translations and replacement
`flash0` fonts, under `RetroArch/system/PPSSPP`. It does not supply users' games
or console firmware. Packaging preserves upstream licenses and README credits.
The assets and user edits must be copied only when the destination file is absent.

`NeoPPSSPPProfile.h` defines the required frontend option boundary:

| Core option | Required value |
| --- | --- |
| `ppsspp_cpu_core` | `Interpreter` |
| `ppsspp_backend` | `opengl` |

The frontend applies these effective options before `retro_load_game` and
rejects changes to those protected keys through its shared menu/API. Existing
user `.opt` files remain editable and are not overwritten. `GET_JIT_CAPABLE`
remains false, which PPSSPP uses for CPU and vertex-decoder JIT decisions.
The pinned GLES build requests `RETRO_HW_CONTEXT_OPENGLES2`; `opengl` selects
that backend without relying on the frontend's preferred-context heuristic.

The pinned `.info` declares `is_experimental = false`, save states supported,
and cheats unsupported. Keep cheats unavailable until their behavior is
qualified. Binary/interface checks and a compiled option-profile test have
passed on Linux; gameplay, rendering, audio, touch/controller input, state
loading and repeated return/relaunch still require an iPhone test.

## Packaging and verification

```sh
python3 build-utils/retroarch/psp/package.py \
  --assets-source /path/to/ppsspp-91a34056.tar.gz \
  --output /path/to/ppsspp-package
python3 build-utils/retroarch/psp/package.py \
  --verify-only --output /path/to/ppsspp-package
python3 -m unittest discover \
  -s build-utils/retroarch/psp/tests -p 'test_*.py' -v
```

Without `--assets-source`, the packager downloads the immutable commit archive
and checks its SHA-256 and length. The core is always read from the repository's
pinned ZIP, never downloaded from mutable `latest` during CI.

The output has only `ppsspp.libretro.framework`, PPSSPP resources/licenses,
`ppsspp-core-entry.json`, an asset index and an audit report. The main RetroArch
package merger must add that verified entry and these files after extracting
its IPA-derived subset. The wrapped dylib bytes remain unchanged until final
application code signing. Its install name remains
`@rpath/ppsspp_libretro.dylib`; the runtime opens the framework executable by
its explicit bundle path rather than linking another app.
