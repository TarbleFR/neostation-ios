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
