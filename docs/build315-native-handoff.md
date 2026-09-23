# Build 315 — native return and RPCS3 allocation

## Report and evidence

After Dusklight, the user reports silent NeoStation menus and an RPCS3
`NEOSTATION_EXACT_ATOMIC_JIT_RESERVATION_V1` failure at the 256 MiB minimum
code/data capacity. No device VM map or kernel return code accompanied that
screenshot. It proves reservation failed, not which particular mapping caused it.

Dusklight's suspend path destroys its SDL audio stream and closes the audio
subsystem. The pinned SDL CoreAudio implementation deactivates the process-wide
AVAudioSession when its last device closes. GameLaunchManager previously only
unpaused SoLoud voices and restored the SFX flag, without activating that session.
An embedded return does not require an application foreground notification.

RPCS3's gap scanner also aborted the whole search on `KERN_INVALID_ADDRESS`.
Apple's XNU `vm_map_locate_space_fixed` can return that value for a hole crossing
an allowed user-allocation range boundary. `vm_region_64` enumerates mappings,
not those policy boundaries. A rejected gap therefore cannot prove that later
gaps are unusable. Reference: apple-oss-distributions/xnu, osfmk/vm/vm_map.c,
`vm_map_locate_space_fixed`, `vm_map_user_range_resolve`, `vm_map_region`.

## Targeted changes

- Continue the existing bounded, page-aligned scan after a VM-policy-rejected
  gap, just as for an occupied gap. Log each rejected candidate, size and kernel
  code. Actual ownership still requires an exact non-overwriting `vm_allocate`;
  no existing mapping is released or overwritten to make room.
- Keep the existing arena minimum, upper bound, data proximity and standard
  capacity selection. Do not reserve memory from the host or prepare JIT early.
- Restore NeoStation's ambient audio session at session completion, before
  resuming its voices. A rapid new launch waits for this handoff so a late audio
  activation cannot interfere with the next core. Preserve music/SFX preferences.

## Verification and limits

The new production-function regression reproduces failure with Build 314's
allocator: an unallocatable visible gap precedes a retained port heap and a
usable 896 MiB window. With the correction, the full 448 + 448 MiB layout is
reserved without touching the retained heap. Existing fragmentation, capacity,
ownership, cleanup, resource failure and initialization recovery tests remain.

The VM-policy issue is confirmed in the allocator and regression, but the
screenshot alone does not establish that it caused this specific iPhone failure.
Device validation must cover Dusklight → NeoStation (music and navigation SFX)
→ RPCS3 → Dusklight, including a rapid launch and multiple returns. If reservation
still fails, the new rejected-gap diagnostic records the exact kernel result.

Compilation, artifact identities and device observations are recorded below as
they become available. A build or simulated test is not an iPhone stability proof.

## Dusklight game language

The native menu now exposes a translated game-language page. Options come from
the pinned Dusklight `available_languages` policy for the inspected disc: PAL
includes French; Japanese discs remain Japanese; the supported Wii US revision 2
also includes French. This changes game language, not the entire upstream UI.

A selection is persisted separately in `NeoDusklightGameLanguage`. It does not
mutate the live configuration: Dusklight's resource paths consult that setting
while some language state is cached at startup. The validated preference is
applied only during the next cold initialization, before `LanguageInit`; a warm
return/resume keeps the current language. The help text explicitly explains
saving the game and reopening NeoStation. The eight added labels are translated
in all twelve catalogs and validated at the host/Core boundary.

The native test executes the actual selection/application bodies through 100
deferred changes, invalid preferences and incompatible disc language lists.
The audio test executes the production manager with controlled activation and
playback dependencies: 100 returns, preserved disabled preferences, an immediate
new launch waiting for the prior handoff, and failure recovery.

The legacy audio-policy source test no longer opens the retired
`release-ipa.yml`; its assertions still check the active `ios-ci.yml` audio patch.
It and the new behavior test are required before candidate packaging.

## Native and host validation record

- Dusklight Core input: `66179a6a83a565dcc35f7b3e4c1212a874be2946`.
  CI run `35886713989` passed, including native menu/language/return tests and
  the UIKit/C++ compilation boundary. The downloaded arm64 framework has SHA-256
  `af7ddd22760dd78e14e2cb6161e7bee24261d0960e62dbf0f0ac2b49fddcc61d`.
  Its 24 canonical source hashes match this repository, and all 35 resource
  hashes match the packaged files. ABI remains 3.
- Flutter behavior preflight at the same input: run `35886713954` passed.
  It includes the three production-manager audio handoff scenarios, the five
  launch navigation tests and the eight carousel tests.
- RPCS3 Core input: `be4f8f3abbf478b18ae782dcdaf290181e92b7a2`.
  CI run `35885420615` passed the startup regressions, iOS compilation and
  binary checks. Downloaded Core SHA-256:
  `bafe4e8ac378179b930379b2720f1a076890543b3c392c364fd043284465dcfc`.
  Its ABI 30, source revision and canonical delta hash match the host inputs.
  The rejected-gap diagnostic is present. Passive-load validation inspected
  2,769 initializers (916 symbol groups), with no forbidden direct-call path
  to the named JIT setup functions within the validator's depth-16 scope.
- The candidate packaging workflow pins these exact successful native runs.
  Dolphin, ARMSX2 and helper inputs retain the Build 314 pins; final IPA
  comparison must verify their bytes before delivery.

## Delivered candidate identity

- Host: `9c4a5b46a16e826c3bdabf22848dc5650a33209a`.
- Full iOS CI: `35891226927`, successful. Flutter analysis, all required tests,
  iOS compilation and final IPA validators passed on this exact revision.
- Artifact: `10764988335`,
  `NeoStation-iOS-Build-315-Native-Return-Language`.
- IPA: `NeoStation-iOS-Build-315-Native-Return-Language.ipa`, 102,350,444 bytes.
- IPA SHA-256:
  `5943fd3ea482dcdd86f7ac089facd5abe3f5b27168539961ee840d479f249609`.
- The downloaded ZIP and IPA hashes match the CI delivery. The IPA reports
  build 315 and bundle `com.neogamelab.neostation`. Its RPCS3 and Dusklight
  bytes exactly match the verified native artifacts above; Dusklight's 35
  resources and passive loading were rechecked in the final archive.
- Byte comparison with Build 314 confirms unchanged Dolphin and ARMSX2 cores,
  all three JIT helper executables, their debugger scripts and the two StikJIT
  scripts. No helper source or pin was changed for this defect.

This candidate still requires the reported cross-core sequence to be tested on
the user's iPhone. KartPad is not included: its verified compilation dependency
and integration contract are recorded in `kartpad-integration.md`.
