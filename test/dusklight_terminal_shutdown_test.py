#!/usr/bin/env python3
"""Lock the one-shot Dusklight teardown and cross-core handoff ordering."""

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

finish = core[core.index("void FinishReturn()") : core.index("void Stop()")]
ordered_finish = [
    "if (inNativeCall) return",
    "[displayLink invalidate]",
    "Suspend(true)",
    "RestoreHost()",
    'TraceResources("before_runtime_shutdown")',
    "NeoDusklight_ShutdownRuntime()",
    "ReleaseHostLifecycle()",
    'TraceResources("after_runtime_shutdown")',
    "session.terminate()",
]
positions = [finish.index(token) for token in ordered_finish]
assert positions == sorted(positions), positions
assert finish.index("if (!stopped)") < finish.index("session.terminate()")
assert finish.index("Emit(", finish.index("session.terminate()")) > finish.index("session.terminate()")
assert "NeoDusklight_ReleaseFrameResources" not in finish
assert "Session suspended" not in core
assert "Resuming the retained native runtime" not in core

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

# Build 319 proved that free() was insufficient: its iPhone log retained the
# exact 256 MiB MEM1 and 24 MiB MEM2 mappings. ABI v6 gives both allocations
# explicit mmap/munmap ownership and fails closed before runtimeReleased.
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
    assert source.index(f"munmap({pointer}, {allocation_size})") < source.index(f"{pointer} = nullptr", source.index(f"munmap({pointer}, {allocation_size})")), region
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
    "d9701056ac8f8e27092228dcf5e83158339ffd7c7e34ad95c0f88e7d858f0f54"
assert manifest["upstream/extern/aurora/lib/dolphin/AR.cpp"] == \
    "c1c7c9c764d456bb3d839465b80e5383f20c416f47fe42fb50f4f86ed66bb839"

state_branch = plugin[plugin.index("- (void)coreState:") : plugin.index("- (void)handleMethodCall:")]
assert '@"runtimeReleased": @YES' in state_branch
dusklight_monitor = manager[manager.index("emulatorExe == 'ios_dusklight_internal'") :]
dusklight_monitor = dusklight_monitor[: dusklight_monitor.index("emulatorExe == 'ios_armsx2_internal'")]
assert dusklight_monitor.index("event['runtimeReleased'] == true") < dusklight_monitor.index("_triggerClose()")
assert "DusklightInternalBridge.didReleaseRuntime" in dusklight_monitor

print("PASS: Dusklight kernel-unmaps MEM1/MEM2 and fails closed before exposing the next in-process core")
