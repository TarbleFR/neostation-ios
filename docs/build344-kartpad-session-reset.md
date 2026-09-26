# KartPad session ownership audit (candidate Build 344)

Build 343 returned through RuntimeMain, released the SDL stream, destroyed the
renderer/fibers, and reset guest memory. That is insufficient for an executable
originally designed to run once per process.

Verified against the v0.5.1 official donor and its pinned runtime source
`d0b8dec62a8c98dd45736a996ae18327ada8fe3f`:

- `VIInit` checks the process-global ViState.initialized flag and returns without
  rebuilding VI state on the second launch. The old guest callbacks, framebuffer
  addresses and retrace deadline survive Memory::Reset/Init. RuntimeMain installs
  ServiceGuestTimingDuringAuroraFrameWait before entering the new guest.
  `test/kartpad_session_reset_test.py` executes the donor's actual ARM64
  AdvanceDueRetraces/AdvanceRetrace and observes dispatch to the previous
  callback before a second VIInit. The clean-state path performs no dispatch.
- InitializePersistentCpuContext only seeds r2/r13 if zero; it does not reset
  the guest registers. SeedCpuContext only resets r1.
- Fiber::Shutdown does not clear the host sleep timer / outstanding park tables,
  or its separate deferred-delete fiber list. Pending NAND completions and open
  NAND host files also outlive the guest RAM they reference.
- Stopping AX's worker alone does not disable the AI DMA callback state.
- NeoStation reactivates AVAudioSession on return, but keeps the existing SoLoud
  device. The exact flutter_soloud 4.0.12 backend only starts a device marked
  stopped; it does not recreate its AudioUnit at the native game boundary.
  NeoStation's existing background/foreground recovery recreates this device
  and reloads its sources. KartPad return now explicitly invokes that recovery,
  preserving enabled/playing preferences and the current music position.

The new DonorSessionReset owns a narrow, verified set of session data. It runs
only after RuntimeMain returns and checks that the fiber manager is stopped.
It uses the original CloseFd function, never commits unfinished NANDSafeOpen
files, never clears save directories, never unloads Objective-C classes, and
never overwrites process-global mutexes/containers with saved bytes. Only plain
CPU/VI/AI state is restored from its pre-first-launch snapshot; containers are
emptied with their C++ operations. GuestFlat's reusable reservation remains.

Validation gates:

- Exact native accessor hashes / instruction witnesses, unchanged donor text.
- ARM64 old-callback reproduction versus clean state at three ASLR slides.
- Native UIKit simulator executes Memory, VI, fibers, sleep timer registration,
  NAND callback enqueue/dequeue, and file close with the production reset header.
  It must reproduce the old state leak and pass 20 corrected session cycles.
- Frontend GameLaunchManager exercises userReturn/languageRestart, audio
  activation/recreation order, rapid relaunch, and disabled sound preferences.
- Core compile and IPA identity checks remain mandatory.

A simulator/subsystem test is not physical-iPhone gameplay validation. No new
Build 343 crash report was attached to the current report; earlier device logs
were from Builds 341/342. Do not state that every reported crash is definitively
identified from a nonexistent Build 343 stack trace.
