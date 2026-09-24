# KartPad native port — integration audit, 23 September 2026

## NeoStation integration resumed — 24 September 2026

Build 322 is the stable NeoStation iOS baseline. KartPad work resumes only on `experimental` and must not modify the Build 322 runtime identity.

Stage 1 introduces the shared Ports import UX and a private `Ports/KartPad` library. The Ports playlist now uses one **Import** menu with **DuskLight** and **Mario Kart Pad** targets. KartPad imports are isolated from DuskLight and generic emulator routing. Until a callable KartPad Core ABI is packaged, launching an imported KartPad title is refused explicitly rather than misrouting it.

The first import profile accepts a raw PAL Mario Kart Wii `RMCP01`, disc 0, revision 0 ISO and stores it canonically as `Ports/KartPad/Games/Mario Kart Wii.iso`. WBFS/extracted DATA support will be connected to the native KartPad validation path rather than accepted on filename alone.


Requested behavior: import Mario Kart Wii into Ports, display it as a normal
scraped game, launch the embedded KartPad runtime with its native controls and
settings, return to NeoStation, and resume without a second application launch.

## Verified upstream inputs

- Project: https://github.com/chrissotraidis/kartpad (GPL-3.0).
- Reviewed development revision: `0d657f361ccf0a03c0b8f9ec97b2bd237e16a658`.
- Maintained iOS runtime pin at that revision:
  `d0b8dec62a8c98dd45736a996ae18327ada8fe3f` in `vendor/runtimes/ios`.
- Stable v0.5.0 source delivery: 361,516,349 bytes,
  SHA-256 `70f1672b99d40114807fa36eb7c12f4d161b1d5a65c13636cf2451f7291a3457`.
- That archive records compilation source revision
  `a2f41d5515c688973e47573ae65504e891e222f1` and recursive source fingerprint
  `204c960d3533eaef4d914306ede88bfdf657a1f0ecf4c0b5259d22961d5d38ad`.
  This release source is distinct from the development revision above.
- Stable iOS IPA: 41,995,797 bytes,
  SHA-256 `7c64144ea996f438aab853e700c8ffa3b8b9db205fdb8033714b07ca6186cadf`.
  Inspection confirms version 0.5.0, build 59, one Mach-O `MH_EXECUTE` executable
  named `KartPad`, and no embedded framework/dylib providing a callable core ABI.

## Concrete build dependency

`REBUILD.md`, step 5 in the verified source archive, requires regeneration of
translation/profile inputs from a supported game. It explicitly excludes those
generated inputs. `scripts/translate-base.sh` requires 29,637 translated
functions and `build_shards/shards.cmake`; the iOS build consumes them.

The supported profile is Mario Kart Wii PAL `RMCP01`, disc 0, revision 0.
The profile verifies these executable inputs:

| Extracted file | SHA-256 |
| --- | --- |
| `sys/main.dol` | `80d18895b39c63bd80f457398bfcbb91b7d16ac116a41a88967e954080155b05` |
| `files/rel/StaticR.rel` | `16d9d146112541fefea701ecb5bc1a496f9d50e4a752fbb5b6778e7c6399f67d` |

Neither the supported disc nor the generated compilation inputs are present in
the current workspace. A supported user-provided disc image or the matching
generated source package is required before a real embedded Core can be built.
The public standalone IPA cannot be passed to the Dusklight framework loader:
it has its own application entry point and no NeoStation ABI.

## Required integration once the inputs are available

1. Pin one source/runtime/dependency set; generate and validate the exact PAL
   base game graph. Preserve its provenance with the resulting framework.
2. Adapt the maintained iOS runtime to the existing host/Core ownership contract:
   private symbols/SDL classes, one host-owned UIKit lifecycle, explicit first
   frame, native settings/controls, input release, audio handoff, and repeatable
   suspension/resume. The standalone runtime's nested main-menu run loop must
   not become a second NeoStation navigation or application loop.
3. Generalize the current Ports dispatch only when the callable core exists:
   separate `Ports/KartPad` import/save/config directories, strict `RMCP01` and
   revision validation, Wii metadata lookup for **Mario Kart Wii**, and native
   session-end monitoring. Do not route KartPad to Dusklight or scrape it as Zelda.
4. Translate every new label/error in all twelve NeoStation languages. Run the
   import, unsupported-disc, first-frame, return, immediate relaunch and
   cross-core tests, then package and inspect the actual framework in the IPA.

Build 322 is the frozen stable baseline. KartPad Stage 1 is import-only and is not advertised as playable until NeoStation has a callable native Core ABI, first-frame/session ownership, audio handoff and repeatable return/relaunch validation.
