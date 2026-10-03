# Embedded RetroArch frontend — stage 1

This directory provides the GPL-3.0-or-later hosted frontend adapter. The
application executable from the requested IPA is **not** loaded or converted.
The matching frontend is compiled from RetroArch commit
`3a6a1e9c4fb4e90044945f84138ae7fad687e1a4` and exports
`NeoRetroArch_GetAPI` ABI version 1.

`build-utils/retroarch/source.json` pins 85 reviewed software core binaries from
the supplied nightly IPA, its separately reviewed GLES3 Mupen64Plus-Next core,
and one separately pinned PPSSPP core. The original
stage 1 smoke commit used 11 cores. `package_ipa.py` verifies
the complete IPA, each selected original signed framework binary, each core
information file and the matching upstream App Store allowlist. It physically
excludes other frameworks and their info files. Required/optional BIOS metadata
is retained, including the unquoted firmware counts in upstream info files.
Original FAT containers each
have one arm64 device slice and remain byte-for-byte unchanged until final
NeoStation signing. PPSSPP is absent from the supplied IPA, so its official
core archive, matching source revision and support assets have independent
SHA-256 pins under `native/retroarch/psp`. Only these upstream support assets
are bundled under `system/PPSSPP`; console BIOS and games remain user files.
Both frontend and PPSSPP corresponding source accompany the native package.
Cores have not yet been qualified on an iPhone.

The frontend has one host-owned iOS view and a bounded main-thread display-link
runloop. Source adaptation removes `UIApplicationMain`, standalone app startup,
standalone window replacement and calls to `exit(0)` in frame scheduling.
Teardown releases only the session view, GL drawable and frontend state. First
frame acknowledgement occurs after GL2 submits an actual game frame.
Controller Select+Start and overlay menu requests use NeoStation's unified
native menu. Select+Start remains consumed until both buttons are released.

User files remain in `Documents/RetroArch`. The regular `config/retroarch.cfg`
is preserved; a session append config pins the embedded view, curated core
routing and paths. All 12 host locales map to RetroArch/libretro languages,
including traditional Chinese. Existing `.opt` core options are handled by
RetroArch's option manager. Imported save/state sorting preferences remain in
the base config; new installs default to flat directories, preserving ordinary
RetroArch save layouts. Pausing uses upstream pause commands, including audio
fade, MIDI silence and frame-timing changes.

Initial graphics use GL2 with GLES2/GLES3. Only `.glslp` shader presets are
supported. The supplied IPA has no shader pack, so presets and their relative
shader references are imported by the user. Overlays and their image assets
come from the supplied IPA. Overlay application reports `pending` until its
actual load completes or fails through the ABI command-result event.

Save/load commands serialize the real libretro core and write atomic raw
states at RetroArch's slot paths. They report serialization, I/O and
unserialization failures. This initial adapter accepts raw libretro states for
the same core/content revision. Imports use the pinned upstream RZIP stream
reader and RASTATE1/raw deserializer, with a 128 MiB decoded-size limit and
4 MiB RZIP chunk limit. Unsupported codecs, malformed files and incompatible
core states fail explicitly; the original imported files are never rewritten.
States cannot be automatically converted between emulator variants. Cheats
use RetroArch's actual cheat manager,
per-game `.cht` persistence and core-defined code validation. Cheat capability
is only advertised when the curated core info declares support.

JIT is disabled for this initial subset. The frontend cannot attach a debugger,
allocate executable pages, alter exception handlers or touch NeoStation's other
JIT implementations. PCSX ReARMed's interpreter option and PPSSPP's
Interpreter/OpenGL options are forced before core initialization and cannot be
switched to incompatible backends through the menu. Imported option files
remain intact. Hardware contexts are restricted to GLES2 or GLES3.0; desktop
OpenGL, GLES3.1+ and Vulkan are refused. Mupen64Plus-Next uses protected Pure
Interpreter, GLideN64 and HLE options, with its threaded renderer disabled.
Its exact donor source revision does not compile the iOS dynarec. Other hardware
cores require a separate reviewed runtime profile; an App Store allowlist entry
alone does not establish driver compatibility or device performance.

## Build and evidence

On macOS with Xcode and Ruby `xcodeproj` 1.27.0:

```sh
bash build-utils/retroarch/build_core.sh \
  --upstream /absolute/path/to/pinned-RetroArch \
  --ipa /absolute/path/to/2026-10-03_RetroArch.ipa \
  --output /absolute/path/to/new-stage1-package
```

Output has `Frameworks/`, `Resources/`, binary identity evidence and the exact
modified corresponding frontend source. It is a stage 1 native package, not a
full NeoStation IPA. The dedicated workflow compiles the real Apple frontend
and the host bridge's controllable simulator lifecycle harness. Passing those
checks does not establish game compatibility, performance or stable relaunch
on a physical iPhone; those remain device qualification gates.
