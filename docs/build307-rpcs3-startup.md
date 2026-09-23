# Build 307 — RPCS3 startup recovery

## Observed Build 306 failures

The supplied milestone and diagnostic logs contain two failed initializations
(PIDs 50535 and 50549) and one successful launch (PID 50546). All three returned
from `dlopen`. The two failures returned initialization status 4 because the JIT
arena could not be reserved. The host then entered `jit_completion_begin` without
a matching completion. The successful launch reserved 448 MiB of code and 256 MiB
of data, sent Universal JIT command 0, completed the helper transaction, passed
the LLVM self-test, and booted BLES00113.

The supplied recording also shows the launch overlay being dismissed. In the
source, its dismissible modal barrier bypassed the manager's existing rule that
dismissal is blocked during the launching phase. Failure handling and delayed
normal closure used `Navigator.pop`, which could close a different route.

These observations establish an arena reservation failure and missing failure
completion. They do not establish that launch speed itself caused the VM layout,
and they are not an iOS crash backtrace.

## Canonical Core changes

Core source commit: `4e0ae3ccb6f58425fa5f2a0e9780f1f180e77a50`.
Core workflow: `35799603880`.

- Enumerate real VM region boundaries and try page-aligned free gaps. Reserve a
  whole candidate with fixed, non-overwriting `vm_allocate`; the VM query alone
  never establishes ownership. Release the returned object port and any failed
  owned reservation.
- Select standard arena capacity within the existing 256 MiB minimum and the
  physical-memory-derived upper bound. A failed larger reservation is fully
  released before selecting a smaller layout. Explicit expanded capacities are
  kept exact. All selection happens before executable page preparation or
  runtime construction.
- Send the existing debugger detach command on initialization failure, so the
  host's completion wait can finish and retain the original error.
- Allow another explicit initialization only after a failure before construction
  of the global runtime. Reuse the log listener. Failures after runtime
  construction begins retain the single-instance guard. No automatic startup
  retries or new reset/shutdown API were added.

The delta remains one hash-locked canonical source patch. The public ABI is 30.
Dolphin, ARMSX2, debugger helper, saves, firmware, pairing files and emulation
settings are outside this change.

## Host changes

- Route touch/back through the existing launch phase check.
- Hold the actual launch dialog route across asynchronous work, and remove that
  route on failure or normal closure.
- Ignore results arriving after that route has been removed.
- Keep the original technical exception on thrown launch failure, and clean up
  the owned dialog. Disposal clears the launch-pending flag.

## Verification

Native regression harnesses compile actual functions extracted from the
canonical source. They cover occupied mappings, exact ownership, query ports,
protection/relocation cleanup, fragmented nearby data, ADRP reach, unaligned free
gaps, standard capacity selection, exact expanded requests, resource failure,
a concurrent mapping, and failure at each explicit initialization step.

The new 704 MiB free-gap case fails with the Build 306 allocator and passes with
the candidate. The failure harness checks detach, original error preservation,
explicit recovery before runtime construction, rejection of later retry, and
single registration of the log listener.

The Flutter harness executes the production launch and delayed-close function
bodies with the real Navigator and controlled native launch results. It covers
rapid taps/back, a second dialog above the launch route, original failure details,
explicit relaunch, external route removal, a late result, and thrown failures.

Initial macOS preflight caught a conflicting mock `mach_port_t` typedef. The
harness was corrected to use Darwin's unsigned type; production source was not
changed for that test issue. Compilation was blocked until this check passed.

Flutter route run `35799947165` passed all five tests on macOS with Flutter
3.47.2. Native Core preflight also passed on macOS, including the Swift helper
handshake check that is unavailable on this Linux workspace.

Core compilation and binary validation passed in run `35799603880`.
The downloaded artifact passed its ZIP digest, source/ABI identity, binary marker,
export and passive-load checks. Core SHA-256:
`3a1b16e8f8bd4e6751c56ba090081c10a325423d1a5a09c86d9d16736161fe0a`.

Final IPA validation is performed by the Build 307 `ios-ci` workflow. A successful build and simulated tests do not establish device
stability; the requested quick PS3 launch must be validated on the user's iPhone.
