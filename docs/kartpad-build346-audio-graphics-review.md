# KartPad Build 346 candidate: audio and graphics review

Device evidence (2026-09-27, Build 345, iPhone17,2 / A18 Pro): the attached
`console.log` shows a 32 kHz stereo output stream, a 7,680-byte (60 ms)
queue, and 63 dropped 384-byte blocks by the first 8,192 checks. The count
remained 63 at 16,384 checks, then reached 80 around the switch from 4x to
2x. After that it stayed 80 at 32,768 checks. Dropped PCM is an evidenced
contributor to crackling, but no device recording isolates every audible pop.

The pinned iOS runtime `d0b8dec6` deliberately uses a 60 ms queue on iOS
and 120 ms elsewhere. The candidate raises iOS capacity to 120 ms with one
verified ARM64 shift in `AudioBackend::QueueHasCapacityLocked`, trading up to
60 ms of extra buffering for tolerance of short bursts. It does not alter the
audio sample rate, mixer cadence, guest timing, or frontend audio lifecycle.
The method's complete original instruction hash is checked before patching;
an ARM64 test executes both byte sequences at three ASLR slides and measures
7,680 versus 15,360 bytes. It does not prove zero audio drops in gameplay.

At 4x the device logs 40.0, 41.1, 39.5 and 33.4 FPS over successive windows;
after selecting 2x it returns to steady 60.0 FPS. The 4x workload renders
16 times the native pixel count, versus four times at 2x. There are no queued
shader pipelines in the slow windows, thermal state is 1 (fair), and memory
footprint reaches about 1.7 GB. There is no evidence that frame interpolation
or a nominal refresh-rate selector can make a 40-FPS base render into 60-FPS
gameplay. Keep 2x as the evidence-backed 60-FPS setting on this device;
3x remains a user-selectable intermediate experiment.

The existing 120/180-FPS frame-interpolation setting is now reachable from
KartPad Settings > Graphics > Advanced graphics as well as the donor's Display
menu. The new anisotropic menu selects 1x, 2x, 4x, 8x or 16x; the existing
unset default displays 16x because Aurora defaults a zero maximum to 16.
The host writes the selection to a checked donor data slot before each
RuntimeMain; a guarded ARM64 gate writes `AuroraConfig.maxTextureAnisotropy`
before Aurora copies the configuration. The pinned source and original
96-byte `aurora_initialize` prologue establish offset 40. The gate is tested
for all choices and ASLR slides, including preservation of the hidden result
register and all other configuration bytes. The setting takes effect on the
next KartPad launch, not as an unsafe live change of cached GPU samplers.

The lifecycle journal also shows session 4 reaching its first frame at
08:16:45 UTC, then a new process/session 1 beginning at 08:16:53 without a
recorded clean shutdown of session 4. This is consistent with an unclean exit
under repeated relaunch stress, but the three attachments contain no .ips
stack trace for that exit. This candidate does not claim to diagnose or fix
that remaining intermittent crash. The native 20-cycle reset probe from
Build 344 remains applicable to unchanged reset code, but on-device stress
acceptance is still required.
