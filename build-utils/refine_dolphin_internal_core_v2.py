#!/usr/bin/env python3
"""Harden the generated Dolphin bridge for reusable, isolated sessions."""

from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: refine_dolphin_internal_core_v2.py <dolphin-checkout>")

root = Path(sys.argv[1]).resolve()
bridge = root / "Source/iOS/Library/NeoStationBridge.mm"
if not bridge.is_file():
    raise SystemExit(f"Generated NeoStation Dolphin bridge is missing: {bridge}")
text = bridge.read_text(encoding="utf-8")

if "#include <algorithm>" not in text:
    text = text.replace("#include <atomic>\n", "#include <algorithm>\n#include <atomic>\n", 1)

old = r'''NS_EXPORT void neostation_dolphin_stop()
{
  auto& system = Core::System::GetInstance();
  if (Core::IsRunning(system))
  {
    AppendLog("game_lifecycle", "stop_requested", "NeoStation requested Dolphin stop.");
    Core::Stop(system);
  }
}
'''
new = r'''NS_EXPORT void neostation_dolphin_stop()
{
  if (!g_initialized.load())
    return;

  auto& system = Core::System::GetInstance();
  if (Core::IsRunning(system) || Core::GetState(system) == Core::State::Starting)
  {
    AppendLog("game_lifecycle", "stop_requested", "NeoStation requested Dolphin stop.");
    Core::Stop(system);
  }

  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
  while (Core::GetState(system) != Core::State::Uninitialized &&
         std::chrono::steady_clock::now() < deadline)
  {
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }

  if (Core::GetState(system) != Core::State::Uninitialized)
  {
    AppendLog("game_lifecycle", "stop_timeout",
              "Dolphin did not reach the Uninitialized state before cleanup timeout.");
    g_launch_running.store(false);
    return;
  }

  Config::Save();
  Core::Shutdown(system);
  UICommon::ShutdownControllers();
  UICommon::Shutdown();

  g_launch_running.store(false);
  g_jit_validated.store(false);
  g_initialized.store(false);
  g_validated_path.clear();
  g_validated_system = -1;
  AppendLog("resource_release", "success",
            "Dolphin released Core, controller, audio/video host services, and session state.");
}
'''
if new not in text:
    if text.count(old) != 1:
        raise SystemExit(
            f"Unexpected generated stop function; expected one anchor, found {text.count(old)}"
        )
    text = text.replace(old, new, 1)

# A DOL/ELF can be authored for either console. Do not allow those extensions to
# bypass explicit GameCube/Wii ownership based solely on their generic platform.
old_platform = r'''bool IsExpectedPlatform(DiscIO::Platform platform, int expected_system)
{
  if (platform == DiscIO::Platform::ELFOrDOL)
    return true;
  if (expected_system == 0)
'''
new_platform = r'''bool IsExpectedPlatform(DiscIO::Platform platform, int expected_system)
{
  if (expected_system == 0)
'''
if new_platform not in text:
    if text.count(old_platform) != 1:
        raise SystemExit("Unexpected platform validation layout")
    text = text.replace(old_platform, new_platform, 1)

bridge.write_text(text, encoding="utf-8")
print(f"Refined generated Dolphin bridge: {bridge}")
