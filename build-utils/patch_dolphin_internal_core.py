#!/usr/bin/env python3
"""Patch a pinned OatmealDome/dolphin-ios checkout for NeoStation embedding."""

from __future__ import annotations

import sys
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("usage: patch_dolphin_internal_core.py <dolphin-checkout>")

root = Path(sys.argv[1]).resolve()
cmake = root / "Source/iOS/Library/CMakeLists.txt"
allocator = root / "Source/Core/Common/MemoryUtil_iOS_LuckTXM.cpp"
bridge = root / "Source/iOS/Library/NeoStationBridge.mm"

if not cmake.is_file() or not allocator.is_file():
    raise SystemExit(f"Not a compatible dolphin-ios checkout: {root}")

cmake_text = cmake.read_text(encoding="utf-8")
anchor = """add_library(dolphin SHARED
  Host.mm
  HostQueue.h
  HostQueue.mm
)
"""
replacement = """add_library(dolphin SHARED
  Host.mm
  HostQueue.h
  HostQueue.mm
  NeoStationBridge.mm
)
"""
if replacement not in cmake_text:
    if cmake_text.count(anchor) != 1:
        raise SystemExit("Unexpected Source/iOS/Library/CMakeLists.txt layout")
    cmake.write_text(cmake_text.replace(anchor, replacement, 1), encoding="utf-8")

allocator_text = allocator.read_text(encoding="utf-8")
# mmap fails with MAP_FAILED, not nullptr. Keep the known upstream allocator
# architecture but make its failure gate correct before relying on it as a real
# executable-memory validation.
allocator_text = allocator_text.replace(
    """  if (!rx_ptr)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed! mmap returned {}", LastStrerrorString());
    return;
  }
""",
    """  if (rx_ptr == MAP_FAILED)
  {
    PanicAlertFmt("AllocateExecutableMemoryRegion failed! mmap returned {}", LastStrerrorString());
    return;
  }
""",
    1,
)
allocator.write_text(allocator_text, encoding="utf-8")

bridge.write_text(r'''// Copyright 2026 NeoStation iOS contributors
// SPDX-License-Identifier: GPL-2.0-or-later

#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iomanip>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include <dispatch/dispatch.h>
#include <libkern/OSCacheControl.h>

#include "Common/FileUtil.h"
#include "Common/MemoryUtil.h"
#include "Common/WindowSystemInfo.h"
#include "Core/Boot/Boot.h"
#include "Core/BootManager.h"
#include "Core/Config/GraphicsSettings.h"
#include "Core/Config/MainSettings.h"
#include "Core/Core.h"
#include "Core/DolphinAnalytics.h"
#include "Core/PowerPC/JitInterface.h"
#include "Core/PowerPC/PowerPC.h"
#include "Core/System.h"
#include "DiscIO/Volume.h"
#include "UICommon/UICommon.h"
#include "VideoCommon/Present.h"
#include "VideoCommon/VideoConfig.h"

#include "HostQueue.h"

namespace
{
std::mutex g_mutex;
std::atomic<bool> g_initialized{false};
std::atomic<bool> g_jit_validated{false};
std::atomic<bool> g_launch_running{false};
std::string g_user_directory;
std::string g_log_path;
std::string g_validated_path;
int g_validated_system = -1;

std::string JsonEscape(const std::string& value)
{
  std::ostringstream out;
  for (const unsigned char ch : value)
  {
    switch (ch)
    {
    case '\\': out << "\\\\"; break;
    case '"': out << "\\\""; break;
    case '\n': out << "\\n"; break;
    case '\r': out << "\\r"; break;
    case '\t': out << "\\t"; break;
    default:
      if (ch < 0x20)
        out << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(ch);
      else
        out << ch;
    }
  }
  return out.str();
}

void AppendLog(const char* stage, const char* status, const std::string& message)
{
  std::lock_guard<std::mutex> guard(g_mutex);
  if (g_log_path.empty())
    return;

  std::ofstream stream(g_log_path, std::ios::app);
  if (!stream)
    return;

  const auto now = std::chrono::system_clock::now();
  const auto epoch_ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            now.time_since_epoch())
                            .count();
  stream << "{\"epochMs\":" << epoch_ms
         << ",\"component\":\"DolphinCore\",\"stage\":\""
         << JsonEscape(stage) << "\",\"status\":\"" << JsonEscape(status)
         << "\",\"message\":\"" << JsonEscape(message) << "\"}\n";
  stream.flush();
}

void SetError(char* buffer, size_t capacity, const std::string& message)
{
  if (buffer == nullptr || capacity == 0)
    return;
  const size_t count = std::min(capacity - 1, message.size());
  std::memcpy(buffer, message.data(), count);
  buffer[count] = '\0';
}

bool IsExpectedPlatform(DiscIO::Platform platform, int expected_system)
{
  if (platform == DiscIO::Platform::ELFOrDOL)
    return true;
  if (expected_system == 0)
    return platform == DiscIO::Platform::GameCubeDisc ||
           platform == DiscIO::Platform::Triforce;
  if (expected_system == 1)
    return platform == DiscIO::Platform::WiiDisc || platform == DiscIO::Platform::WiiWAD;
  return false;
}

bool ValidateImageInternal(const std::string& path, int expected_system, std::string* error)
{
  if (!File::Exists(path))
  {
    *error = "The selected game image does not exist.";
    return false;
  }

  std::unique_ptr<DiscIO::Volume> volume = DiscIO::CreateVolume(path);
  if (!volume)
  {
    *error = "Dolphin could not recognize the selected ISO/RVZ/WBFS image.";
    return false;
  }

  const DiscIO::Platform platform = volume->GetVolumeType();
  if (!IsExpectedPlatform(platform, expected_system))
  {
    *error = expected_system == 0
                 ? "The selected image is not a GameCube title."
                 : "The selected image is not a Wii title.";
    return false;
  }

  return true;
}

bool InitializeInternal(const std::string& user_directory, std::string* error)
{
  if (g_initialized.load())
    return g_user_directory == user_directory;

  __block bool initialized = false;
  dispatch_sync(dispatch_get_main_queue(), ^{
    try
    {
      Core::DeclareAsHostThread();
      UICommon::SetUserDirectory(user_directory);
      UICommon::CreateDirectories();
      UICommon::Init();

      WindowSystemInfo controller_wsi;
      controller_wsi.type = WindowSystemType::iOS;
      UICommon::InitControllers(controller_wsi);

      // Initializes services required by Wii startup. Analytics itself remains
      // disabled in the iOS core build.
      DolphinAnalytics::Instance().ReportDolphinStart("neostation-ios");
      initialized = true;
    }
    catch (...)
    {
      initialized = false;
    }
  });

  if (!initialized)
  {
    *error = "Dolphin UICommon/Core initialization failed.";
    return false;
  }

  g_user_directory = user_directory;
  g_initialized.store(true);
  return true;
}

bool RunExecutableMemoryProbe(std::string* error)
{
#if !defined(__aarch64__)
  *error = "The embedded Dolphin JIT test requires an ARM64 device.";
  return false;
#else
  // The first call enters Dolphin's current TXM allocator. It allocates the
  // 512 MiB RX region and stops at BRK #0x69 with address/length in x0/x1.
  // Returning from this function means the legacy script advanced the PC.
  Common::SetJitType(Common::JitType::LuckTXM);
  AppendLog("legacy_handshake", "started", "Calling Dolphin BRK #0x69 allocator protocol.");
  Common::AllocateExecutableMemoryRegion();
  AppendLog("legacy_handshake", "returned", "Dolphin legacy breakpoint returned to the host.");

  constexpr size_t kProbeSize = 0x4000;
  void* rx = Common::AllocateExecutableMemory(kProbeSize);
  if (rx == nullptr)
  {
    *error = "Dolphin did not provide executable memory after the legacy handshake.";
    return false;
  }

  const ptrdiff_t writable_diff = Common::AllocateWritableRegionAndGetDiff(rx, kProbeSize);
  if (writable_diff == 0)
  {
    *error = "Dolphin did not create the writable alias for its RX JIT region.";
    return false;
  }

  auto* rw = reinterpret_cast<std::uint32_t*>(
      reinterpret_cast<std::uint8_t*>(rx) + writable_diff);
  // mov w0, #42 ; ret
  rw[0] = 0x52800540;
  rw[1] = 0xD65F03C0;
  sys_icache_invalidate(rx, 2 * sizeof(std::uint32_t));

  using ProbeFunction = int (*)();
  const auto probe = reinterpret_cast<ProbeFunction>(rx);
  const int value = probe();
  if (value != 42)
  {
    *error = "Executable JIT memory returned an unexpected probe value.";
    return false;
  }

  // The allocator owns this tiny block until process exit. Avoid invoking the
  // upstream LuckTXM free path here because the RX/RW alias bookkeeping is
  // global and the real JIT will immediately reuse the same arena.
  AppendLog("executable_memory", "success", "ARM64 code executed from Dolphin RX memory and returned 42.");
  return true;
#endif
}

void StartEndMonitor()
{
  std::thread([] {
    auto& system = Core::System::GetInstance();
    while (Core::GetState(system) == Core::State::Starting || Core::IsRunning(system))
      std::this_thread::sleep_for(std::chrono::milliseconds(100));

    g_launch_running.store(false);
    AppendLog("game_lifecycle", "ended", "Dolphin core stopped normally or left the running state.");
    dispatch_async(dispatch_get_main_queue(), ^{
      Core::DeclareAsHostThread();
    });
  }).detach();
}
}  // namespace

#define NS_EXPORT extern "C" __attribute__((visibility("default")))

NS_EXPORT const char* neostation_dolphin_bridge_version()
{
  return "neostation-dolphin-bridge/1";
}

NS_EXPORT int32_t neostation_dolphin_initialize(const char* user_directory,
                                                 const char* log_path,
                                                 char* error,
                                                 size_t error_capacity)
{
  if (user_directory == nullptr || log_path == nullptr)
  {
    SetError(error, error_capacity, "Missing Dolphin user directory or log path.");
    return 0;
  }

  g_log_path = log_path;
  AppendLog("core_initialization", "started", "Initializing embedded Dolphin services.");
  std::string reason;
  if (!InitializeInternal(user_directory, &reason))
  {
    AppendLog("core_initialization", "failure", reason);
    SetError(error, error_capacity, reason);
    return 0;
  }

  AppendLog("core_initialization", "success", "Embedded Dolphin services initialized in NeoStation.");
  return 1;
}

NS_EXPORT int32_t neostation_dolphin_validate_image(const char* game_path,
                                                     int32_t expected_system,
                                                     char* error,
                                                     size_t error_capacity)
{
  if (game_path == nullptr)
  {
    SetError(error, error_capacity, "Missing game path.");
    return 0;
  }
  std::string reason;
  if (!ValidateImageInternal(game_path, expected_system, &reason))
  {
    AppendLog("image_validation", "failure", reason);
    SetError(error, error_capacity, reason);
    return 0;
  }
  g_validated_path = game_path;
  g_validated_system = expected_system;
  AppendLog("image_validation", "success", "Dolphin accepted the game image and expected platform.");
  return 1;
}

NS_EXPORT int32_t neostation_dolphin_prepare_legacy_jit(char* error,
                                                         size_t error_capacity)
{
  if (!g_initialized.load())
  {
    SetError(error, error_capacity, "Dolphin core is not initialized.");
    return 0;
  }

  if (g_jit_validated.load())
  {
    AppendLog("jit_validation", "cached", "Previously validated executable Dolphin arena is still active.");
    return 1;
  }

  std::string reason;
  if (!RunExecutableMemoryProbe(&reason))
  {
    AppendLog("executable_memory", "failure", reason);
    SetError(error, error_capacity, reason);
    return 0;
  }
  g_jit_validated.store(true);
  AppendLog("jit_validation", "success", "Legacy handshake and executable ARM64 probe both passed.");
  return 1;
}

NS_EXPORT int32_t neostation_dolphin_launch(const char* game_path,
                                             int32_t expected_system,
                                             void* metal_layer,
                                             double metal_scale,
                                             char* error,
                                             size_t error_capacity)
{
  if (!g_initialized.load() || !g_jit_validated.load())
  {
    SetError(error, error_capacity, "Dolphin launch was requested before the real JIT gate passed.");
    return 0;
  }
  if (game_path == nullptr || metal_layer == nullptr)
  {
    SetError(error, error_capacity, "Missing game path or CAMetalLayer.");
    return 0;
  }
  if (g_launch_running.load())
  {
    SetError(error, error_capacity, "Another Dolphin game is already running.");
    return 0;
  }

  std::string reason;
  if (g_validated_path != game_path || g_validated_system != expected_system ||
      !ValidateImageInternal(game_path, expected_system, &reason))
  {
    if (reason.empty())
      reason = "The game image changed after validation.";
    AppendLog("image_handoff", "failure", reason);
    SetError(error, error_capacity, reason);
    return 0;
  }

  auto volume = DiscIO::CreateVolume(game_path);
  if (!volume)
  {
    SetError(error, error_capacity, "Dolphin could not reopen the validated image.");
    return 0;
  }

  Config::SetBase(Config::MAIN_CPU_CORE, PowerPC::CPUCore::JITARM64);
  Config::SetBase(Config::MAIN_GFX_BACKEND, "Metal");
  Config::SetBase(Config::GFX_VERTEX_LOADER_TYPE, VertexLoaderType::Native);

  if (expected_system == 0)
  {
    const std::string region_directory = Config::GetDirectoryForRegion(volume->GetRegion());
    const std::string ipl_path = Config::GetBootROMPath(region_directory);
    const bool has_ipl = File::Exists(ipl_path);
    Config::SetBase(Config::MAIN_SKIP_IPL, !has_ipl);
    AppendLog("ipl_selection", has_ipl ? "success" : "not_installed",
              has_ipl ? "Validated regional IPL will be used." :
                        "No matching IPL installed; Dolphin HLE boot will be used.");
  }

  std::vector<std::string> paths{game_path};
  std::unique_ptr<BootParameters> boot =
      BootParameters::GenerateFromFile(paths, BootSessionData());
  if (!boot)
  {
    SetError(error, error_capacity, "Dolphin could not generate boot parameters for the image.");
    return 0;
  }

  WindowSystemInfo wsi;
  wsi.type = WindowSystemType::iOS;
  wsi.render_surface = metal_layer;
  wsi.render_surface_scale = metal_scale;

  dispatch_sync(dispatch_get_main_queue(), ^{
    Core::UndeclareAsHostThread();
  });

  __block bool booted = false;
  DOLHostQueueRunSync(^{
    auto& system = Core::System::GetInstance();
    booted = BootManager::BootCore(system, std::move(boot), wsi);
  });
  if (!booted)
  {
    dispatch_async(dispatch_get_main_queue(), ^{
      Core::DeclareAsHostThread();
    });
    const std::string message = "Dolphin BootCore rejected the game.";
    AppendLog("core_boot", "failure", message);
    SetError(error, error_capacity, message);
    return 0;
  }

  auto& system = Core::System::GetInstance();
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);
  while (Core::GetState(system) == Core::State::Starting &&
         std::chrono::steady_clock::now() < deadline)
  {
    std::this_thread::sleep_for(std::chrono::milliseconds(25));
  }

  if (!Core::IsRunning(system))
  {
    const std::string message = "Dolphin left the Starting state without running the game.";
    AppendLog("core_boot", "failure", message);
    SetError(error, error_capacity, message);
    return 0;
  }
  if (Config::Get(Config::MAIN_CPU_CORE) != PowerPC::CPUCore::JITARM64 ||
      system.GetJitInterface().GetCore() == nullptr)
  {
    Core::Stop(system);
    const std::string message = "Dolphin JITARM64 did not initialize; launch was blocked.";
    AppendLog("jitarm64", "failure", message);
    SetError(error, error_capacity, message);
    return 0;
  }
  AppendLog("jitarm64", "success", "Dolphin created the ARM64 JIT core.");

  if (!g_presenter)
  {
    Core::Stop(system);
    const std::string message = "Dolphin Metal presenter did not initialize.";
    AppendLog("metal", "failure", message);
    SetError(error, error_capacity, message);
    return 0;
  }
  AppendLog("metal", "success", "Dolphin Metal presenter is active.");

  g_launch_running.store(true);
  AppendLog("game_handoff", "success", "Game image was submitted to the embedded Dolphin core.");
  StartEndMonitor();
  return 1;
}

NS_EXPORT int32_t neostation_dolphin_is_running()
{
  return g_launch_running.load() ? 1 : 0;
}

NS_EXPORT void neostation_dolphin_set_paused(int32_t paused)
{
  auto& system = Core::System::GetInstance();
  if (Core::IsRunning(system))
    Core::SetState(system, paused ? Core::State::Paused : Core::State::Running);
}

NS_EXPORT void neostation_dolphin_stop()
{
  auto& system = Core::System::GetInstance();
  if (Core::IsRunning(system))
  {
    AppendLog("game_lifecycle", "stop_requested", "NeoStation requested Dolphin stop.");
    Core::Stop(system);
  }
}
''', encoding="utf-8")

print(f"Patched embedded Dolphin core at {root}")
