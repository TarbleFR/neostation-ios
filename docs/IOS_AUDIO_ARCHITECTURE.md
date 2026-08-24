# iOS audio architecture

NeoStation uses one shared iOS `AVAudioSession` and several
independent playback clients.

## Ownership

- `AudioPolicyService` and the native
  `ExternalFolderAccessPlugin` own the single app-wide session.
- The category is `.ambient` with `.mixWithOthers`, so the iPhone
  Ring/Silent switch remains authoritative.
- The policy is applied only at application startup/resume, after
  the shared SoLoud engine is created, and after native
  interruption/route events.

## Playback clients

- SoLoud SFX play directly from preloaded sources.
- Home-menu music manages only its own source and handle.
- The music player manages only its own source, handle, volume and
  ducking.
- AVPlayer previews manage only controller creation, volume,
  looping, playback and disposal.

No reader changes `AVAudioSession` during a normal play, pause,
volume or stop operation.

## video_player compatibility patch

Flutter's iOS `video_player_avfoundation` normally upgrades the
shared category to `.playback`, which intentionally ignores the
Ring/Silent switch. Every iOS build runs:

`build-utils/patch_ios_video_player_audio_session.py`

The patch disables that category upgrade and makes the per-player
`mixWithOthers` hook a no-op. It fails closed if a future plugin
update changes the expected Swift source, preventing a build from
silently restoring the conflicting policy.

## Preserved preview safeguards

The fork keeps the proven preview lifecycle protections:

- two-second selection stability delay before AVPlayer creation;
- selection generation invalidation;
- serialized controller replacement/disposal;
- muted startup and short volume ramp;
- stale-controller checks after asynchronous operations.
