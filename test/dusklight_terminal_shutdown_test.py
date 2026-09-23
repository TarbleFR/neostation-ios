#!/usr/bin/env python3
"""Lock the one-shot Dusklight teardown and cross-core handoff ordering."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
core = (ROOT / "native/dusklight/core/NeoDusklightCore.mm").read_text()
game = (ROOT / "native/dusklight/upstream/src/m_Do/m_Do_main.cpp").read_text()
plugin = (ROOT / "packages/dusklight_internal_bridge/ios/Classes/DusklightInternalBridgePlugin.mm").read_text()
manager = (ROOT / "lib/services/game_launch_manager.dart").read_text()

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
]
positions = [shutdown.index(token) for token in ordered_shutdown]
assert positions == sorted(positions), positions
assert "ShutdownState::InProgress" in shutdown
assert shutdown.index("ShutdownState::Complete;") > shutdown.index("borealis::log::shutdown()")

state_branch = plugin[plugin.index("- (void)coreState:") : plugin.index("- (void)handleMethodCall:")]
assert '@"runtimeReleased": @YES' in state_branch
dusklight_monitor = manager[manager.index("emulatorExe == 'ios_dusklight_internal'") :]
dusklight_monitor = dusklight_monitor[: dusklight_monitor.index("emulatorExe == 'ios_armsx2_internal'")]
assert dusklight_monitor.index("event['runtimeReleased'] == true") < dusklight_monitor.index("_triggerClose()")
assert "DusklightInternalBridge.didReleaseRuntime" in dusklight_monitor

print("PASS: terminal Dusklight teardown completes before NeoStation exposes the next in-process core")
