#!/usr/bin/env python3
"""Lock warm-return behavior and the fatal terminal teardown ordering."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "native/dusklight/core/NeoDusklightCore.mm").read_text()
game = (ROOT / "native/dusklight/upstream/src/m_Do/m_Do_main.cpp").read_text()
plugin = (ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightInternalBridgePlugin.mm").read_text()
manager = (ROOT / "lib/services/game_launch_manager.dart").read_text()
threads = (ROOT / "native/dusklight/upstream/src/dusk/OSThread.cpp").read_text()
mutexes = (ROOT / "native/dusklight/upstream/src/dusk/OSMutex.cpp").read_text()
messages = (ROOT / "native/dusklight/upstream/src/dusk/stubs.cpp").read_text()
mem1 = (ROOT / "native/dusklight/upstream/extern/aurora/lib/dolphin/os/OSMemory.cpp").read_text()
aram = (ROOT / "native/dusklight/upstream/extern/aurora/lib/dolphin/AR.cpp").read_text()
manifest = json.loads((ROOT / "native/dusklight/upstream-manifest.json").read_text())

# A normal Return to Library is a logical session stop. It must release the
# transient GPU footprint, restore NeoStation, and retain the initialized
# runtime so the same disc can be reopened without another game_main entry.
finish = core[core.index("void FinishReturn()") : core.index("void TerminalShutdown(")]
ordered_finish = [
    "if (inNativeCall) return",
    "[displayLink invalidate]",
    "Suspend(true)",
    'TraceResources("before_graphics_release")',
    "NeoDusklight_ReleaseFrameResources()",
    "RestoreHost()",
    'TraceResources("return_to_host")',
    "session.finish()",
]
positions = [finish.index(token) for token in ordered_finish]
assert positions == sorted(positions), positions
assert "NeoDusklight_ShutdownRuntime()" not in finish
assert "ReleaseHostLifecycle()" not in finish
assert "session.terminate()" not in finish
assert "Session suspended" in finish
assert "Resuming the retained native runtime" in core

# Fatal runtime failure still crosses the complete native shutdown barrier.
terminal = core[core.index("void TerminalShutdown(") : core.index("void Stop()")]
ordered_terminal = [
    "[displayLink invalidate]",
    "Suspend(true)",
    "RestoreHost()",
    "session.requestStop()",
    'TraceResources("before_runtime_shutdown")',
    "NeoDusklight_ShutdownRuntime()",
    "ReleaseHostLifecycle()",
    'TraceResources("after_runtime_shutdown")',
    "session.terminate()",
]
positions = [terminal.index(token) for token in ordered_terminal]
assert positions == sorted(positions), positions
assert terminal.index("if (!stopped)") < terminal.index("session.terminate()")
assert terminal.index("Emit(", terminal.index("session.terminate()")) > terminal.index("session.terminate()")

lifecycle = core[core.index("void ReleaseHostLifecycle()") : core.index("void FinishReturn()")]
for token in (
    "[startTimer invalidate]",
    "[displayLink invalidate]",
    "removeObserver:controls",
    "[menuButton removeFromSuperview]",
    "controls = nil",
    "sdlWindow = nullptr",
    "gameWindow = nil",
):
    assert token in lifecycle, token

# The one-shot destructive path itself remains complete for fatal failures.
shutdown = game[game.index("bool NeoDusklight_ShutdownGame()") : game.index("bool JKRHeap::dump_sort()")]
ordered_shutdown = [
    "borealis::shutdown()",
    "daMP_c_Finish()",
    "mDoMch_Destroy()",
    "dusk::audio::Shutdown()",
    "OSResetSystem(OS_RESET_SHUTDOWN, 0, 0)",
    "NeoDusklight_JoinGameThreads()",
    "aurora_dvd_close()",
    "dusk::ui::shutdown()",
    "dusk::texture_replacements::shutdown()",
    "dusk::config::shutdown()",
    "aurora_shutdown()",
    "borealis::sentry::shutdown()",
    "borealis::log::shutdown()",
    "NeoDusklight_ReleaseMessageQueueRecords()",
    "NeoDusklight_ReleaseMutexRecords()",
    "NeoDusklight_ReleaseThreadRecords()",
    "NeoDusklight_ReleaseARAM()",
    "NeoDusklight_ReleaseMEM1()",
    "Kernel unmap barrier: ARAM=%d MEM1=%d",
    "malloc_zone_pressure_relief(nullptr, 0)",
]
positions = [shutdown.index(token) for token in ordered_shutdown]
assert positions == sorted(positions), positions
assert "ShutdownState::InProgress" in shutdown
assert "ShutdownState::Failed" in shutdown
assert "aramRelease <= 0 || mem1Release <= 0" in shutdown
assert shutdown.index("ShutdownState::Complete;") > shutdown.index("borealis::log::shutdown()")

# The explicit mmap/munmap ownership from Builds 319-320 remains unchanged.
assert "config.mem1Size = 256 * 1024 * 1024" in game
assert "config.mem2Size = 24 * 1024 * 1024" in game
for source, region, pointer, allocation_size in (
    (mem1, "MEM1", "MEM1Start", "sMEM1AllocationSize"),
    (aram, "ARAM", "sAramBuffer", "sAramAllocationSize"),
):
    apple = source[source.index("#if defined(__APPLE__)"):]
    assert "MAP_PRIVATE | MAP_ANON" in apple, region
    assert "mmap(nullptr" in apple, region
    assert f"munmap({pointer}, {allocation_size})" in source, region
    assert f"NEODUSKLIGHT_VM_RELEASE region={region}" in source, region
    unmap = source.index(f"munmap({pointer}, {allocation_size})")
    assert unmap < source.index(f"{pointer} = nullptr", unmap), region
assert "MEM1End = nullptr" in mem1 and "OSBaseAddress = 0" in mem1
assert 'extern "C" int NeoDusklight_ReleaseARAM()' in aram
assert 'extern "C" int NeoDusklight_ReleaseMEM1()' in mem1
for reset in ("AR_StackPointer = 0", "AR_BlockLength = nullptr", "AR_FreeBlocks = 0", "AR_init_flag = FALSE"):
    assert reset in aram, reset
for source, release in (
    (threads, "NeoDusklight_ReleaseThreadRecords"),
    (mutexes, "NeoDusklight_ReleaseMutexRecords"),
    (messages, "NeoDusklight_ReleaseMessageQueueRecords"),
):
    function = source[source.index(release):]
    assert "map.clear()" in function and "map.rehash(0)" in function, release
assert manifest["upstream/extern/aurora/lib/dolphin/os/OSMemory.cpp"] == \
    "4464ce818124cb84f313b63c75892d22249bd300ba8bb345cab322d7f8c8e153"
assert manifest["upstream/extern/aurora/lib/dolphin/AR.cpp"] == \
    "4393e2393ea6577af55dbdf9f65de9bdcf671f9181cf5382c228dcd07d2fff7e"

# IDLE means the retained runtime is reusable; only ENDED means the destructive
# fatal barrier ran. Returning to NeoStation must not be gated on destruction.
state_branch = plugin[plugin.index("- (void)coreState:") : plugin.index("- (void)handleMethodCall:")]
assert '@"runtimeReleased": @(state == NEO_DUSKLIGHT_ENDED)' in state_branch
assert '@"restartRequired": @(state == NEO_DUSKLIGHT_ENDED)' in state_branch
dusklight_monitor = manager[manager.index("emulatorExe == 'ios_dusklight_internal'") :]
dusklight_monitor = dusklight_monitor[: dusklight_monitor.index("emulatorExe == 'ios_armsx2_internal'")]
assert "event['runtimeReleased'] == true" not in dusklight_monitor
assert "DusklightInternalBridge.didReleaseRuntime" not in dusklight_monitor
assert "_triggerClose()" in dusklight_monitor

print("PASS: warm return is reusable; fatal failures still retain the full kernel-unmap barrier")
