# Candidate367: imports and file-backed memory

Private test candidate on experimental. Public0.0.2/main and all emulator Core
identities are retained. No iPhone8GiB or game-stability result is claimed by CI.

## Cheats

- Cheats has a separate Import file row. The importer opens Files without
  presenting the manual form. Named TXT/INI lists preview and save each entry.
- The supplied GR8P69 GCT contains four32-bit write commands, one compiled
  payload and no names/group boundaries. It is labelled a combined code and
  can be previewed as such. No four names are fabricated and multiline codes
  are never split arbitrarily. For individual named switches, use the original
  Ocarina TXT/INI. Remove the previous combined user entry first to avoid using
  its commands alongside the same named entries. New imports stay disabled.
- Added/imported controls remain separate; first cheat toggle/deletion offsets
  are tested after adding the row. Hardcore guards remain intact.

## HD textures (GameCube/Wii)

Graphics → HD textures → Import a folder/ZIP. Use the exact six-character game
folder, e.g. GR8P69/tex1_...png. Paths and names are preserved below GameID.
Supported files are PNG/DDS in the pinned Dolphin texture loader. A GameID
match identifies the region; it does not prove that every texture hash or game
revision is compatible. The user still checks the pack's author instructions.

The host streams ZIP extraction into a private staging directory, verifies CRC
and file signatures, rejects duplicate/case collisions, links and unsupported
archives, and caps the pack at2GiB/20000textures with128MiB per file. It retains
1GiB disk headroom. It writes only this game's texture directory and the exact
revision's HiresTextures/CacheHiresTextures settings, preserving cheats and
other keys. It replaces the preceding pack only after staging succeeds.

Import enables HiresTextures=True and CacheHiresTextures=False. Quit/relaunch
the game to apply; there is no global RAM preload or live Core ABI change.

## Memory:8GiB target and actual scope

NeoSwap is an iOS framework with one host allocator and an existing RPCS3
client. At the maintainer’s request,8GiB is the permanent automatic runtime
budget. Startup applies it without reading the previous optional-budget
preference, including a previous Off setting. No Flutter activation/configure
command or budget selector remains. The panel is diagnostics only. Files are
reserved as allocations need them, with2GiB free headroom; startup does not
reserve8GiB of disk or add physical RAM. The native allocator’s internal
reconfiguration API stays available for tests and keeps live-ownership guards.

The new capacity exercise can request64/128/512MiB or1/2/4/8GiB. It stops while
game-owned mappings are live. It allocates distinct file-backed blocks, writes
all bytes, synchronizes them, asks the OS to discard clean resident pages,
then reloads and verifies all requested bytes before releasing every block.
The discard operation is a hint and is not reported as proven RAM savings.
On iOS, testing aborts if reported process headroom drops below256MiB.
Diagnostics record before/write/sync/verify/release and physical footprint.
The test needs more than10GiB of available storage for an8GiB run.

The production client still covers only CPU-side RSX arrays/cache allocations
of1–256MiB.32 such blocks can occupy the8GiB budget. Guest RAM is already
file-backed in the pinned RPCS3 port. Neither setting expands emulated PS3
hardware RAM nor migrates arbitrary C++ objects, JIT executable pages or GPU
images. Physical RAM and virtual mappings must not simply be added: resident
pages can be counted in both. The goal is verified usable data capacity and
lower measured charged footprint, then stability in the same game scene.

## Madeira and donation investigation

Audited willfaust/Madeira d5a8e0a60804bddf48a9efa751adec52ba9a4bda,
build/ntdll-unix/virtual_ios.c, “FILE-BACKED GUEST DATA TIER”. It explicitly
describes MAP_SHARED dirty pages as external/file-backed and reports a512MiB
on-phone canary with roughly2MiB footprint rise. These are the upstream
author's reported measurements, not a NeoStation result. Its classic/blocks/
wide modes route Wine guest commits, exclude JIT/guard/copy-on-write ranges
and copy back before executable protection. NeoSwap routes a smaller set of
RPCS3 host allocations; identical mapping flags alone do not prove equivalent
coverage or performance. No Madeira code was copied into this candidate.

Stossy11's announcement describes donated memory across helper processes with
separate limits, requiring app integration and still needing GetMoreRam:
https://www.reddit.com/r/EmulationOniOS/comments/1wtcj5m/iosipados_ram_limit_workaround/
The official source link is https://git.ryujinx.app/projects/MeloNX; it returned
502 from this environment during the audit. No donation SDK/ABI or helper
implementation was obtained. The user's screenshot says their Madeira
contact also has a private framework; it supplies no binary, headers or API.
That private package remains a separate integration dependency, not an
implemented8GiB donation feature. Useful inputs: xcframework/source, C API,
supported iOS versions, helper/app-extension packaging, entitlements, license,
and a read/write/lifecycle example. No contact message has been sent.

Apple distinguishes address-space allocations from charged physical footprint:
https://developer.apple.com/videos/play/wwdc2022/10106/
Increased-memory-limit/extended-virtual-addressing are already requested by
the project. Effective privileges depend on the signed provisioning profile.

## Automatic policy regression

The earlier optional Off/selected-budget UI contract was retired at the
maintainer’s request. Its replacement asserts automatic8GiB startup despite
a previous Off preference, no activation command, read-only diagnostics,
automatic game allocations, retained live-game refusal, and cleanup. Native
quota/reconfiguration/failure gates and all core/ABI/JIT pins remain.

## Required acceptance

1. Native allocator failure/concurrency and64MiB reload tests pass.
2. On macOS,8GiB of distinct data is written/synced/reloaded/verified with no
   outstanding mappings; report footprint separately. This is host evidence.
3. UIKit import regression uses the supplied GCT bytes and a labelled TXT.
4. On the actual iPhone, first test64MiB, then512MiB, then8GiB with enough
   storage. Retain JSON and effective entitlement diagnostics.
5. In a development device harness, compare the same RPCS3 game scene against
   the original allocator, then the automatic policy after fresh launches.
   Require integrity, lower measured footprint and acceptable frame time.
   A working capacity test alone is not a validated game memory extension.
