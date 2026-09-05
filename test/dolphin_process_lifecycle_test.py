"""Execute the shipped lifecycle across alternating consoles and failed launches."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def bridge_source():
    spec = importlib.util.spec_from_file_location('dolphin_bridge_lifecycle',
        ROOT / 'build-utils/patch_dolphin_internal_core_v2.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.BRIDGE_SOURCE


def function(source, signature):
    start = source.index(signature)
    opening = source.index('\n{', start)
    closing = source.index('\n}', opening)
    # Queue blocks have the same capture/lifetime here as the production
    # synchronous host call. The harness instruments host affinity and joins.
    return source[start:closing + 2].replace('^{', '[&]{')


class DolphinProcessLifecycleTests(unittest.TestCase):
    def test_alternating_consoles_keep_process_services_and_release_each_game(self):
        compiler = shutil.which('c++') or shutil.which('clang++')
        if not compiler:
            self.skipTest('C++ compiler required')
        source = bridge_source()
        harness = r'''
#include <atomic>
#include <cassert>
#include <cstdint>
#include <mutex>
#include <optional>
#include <string>
#include <vector>
int ui_init=0, controllers_init=0, process_shutdown=0, joins=0, host_depth=0;
bool uninitialized=true, stop_requested=false;
std::vector<std::string> stages;
std::mutex g_state_mutex;
std::atomic<bool> g_initialized{false}, g_running{false}, g_cleanup_started{false};
std::atomic<bool> g_jit_handshake{false}, g_executable_probe{false}, g_devices_changed{false};
std::atomic<int> g_boot_language{-1};
std::string g_user_directory, g_system_directory, g_log_path, g_validated_game, g_validated_system;
bool g_validated_wii_menu=false;
void* g_metal_surface=nullptr;
double g_metal_scale=1;
std::optional<int> g_devices_callback;
namespace Core {
struct System { static System& GetInstance() { static System s; return s; } };
bool IsUninitialized(System&) { return uninitialized; }
void Stop(System&) { assert(host_depth); stop_requested=true; }
void Shutdown(System&) {
 assert(host_depth && stop_requested); ++joins; uninitialized=true; stop_requested=false;
}
}
namespace Config { void Save() { assert(host_depth); } void Load() { assert(host_depth); } }
enum class WindowSystemType { iOS };
struct WindowSystemInfo { WindowSystemType type; };
namespace UICommon {
void SetUserDirectory(const std::string&) { assert(host_depth); }
void CreateDirectories() { assert(host_depth); }
void Init() { assert(host_depth); ++ui_init; }
void InitControllers(WindowSystemInfo) { assert(host_depth); ++controllers_init; }
void ShutdownControllers() { ++process_shutdown; }
void Shutdown() { ++process_shutdown; }
}
struct ControllerInterface {
 template<class F> int RegisterDevicesChangedCallback(F) { assert(host_depth); return 7; }
 void UnregisterDevicesChangedCallback(int) { ++process_shutdown; }
} g_controller_interface;
struct DolphinAnalytics {
 static DolphinAnalytics& Instance() { static DolphinAnalytics d; return d; }
 void ReportDolphinStart(const char*) {}
};
namespace ciface::iOS {
struct StateManager {
 static StateManager* GetInstance() { static StateManager s; return &s; }
 void Init() { assert(host_depth); assert(uninitialized); }
};
}
void ApplyConsolePreferences() { assert(host_depth); }
void ConfigurePhysicalControllers() { assert(host_depth); }
void ResetInputProfiles() {}
void DeclareMainAsHostThread() {}
void UndeclareMainAsHostThread() {}
void Log(const std::string& stage, const std::string&) { stages.push_back(stage); }
template<class F> void DOLHostQueueRunSync(F block) { ++host_depth; block(); --host_depth; }
'''
        for signature in ('void ResetSessionFlags()', 'void ShutdownRuntime(',
                          'int32_t neostation_dolphin_initialize(',
                          'int32_t neostation_dolphin_stop('):
            harness += '\n' + function(source, signature)
        harness += r'''
int main() {
 assert(neostation_dolphin_initialize(nullptr,"Sys","bad")==0);
 assert(ui_init==0);
 for (int cycle=0; cycle<20; ++cycle) {
   const std::string logfile="session"+std::to_string(cycle);
   assert(neostation_dolphin_initialize("User","Sys",logfile.c_str())==1);
   assert(g_log_path==logfile);
   assert(ui_init==1 && controllers_init==1);
   assert(!g_running && !g_jit_handshake && !g_executable_probe);
   assert(g_validated_game.empty() && g_validated_system.empty() && !g_validated_wii_menu);
   assert(g_metal_surface==nullptr && g_boot_language==-1);
   assert(neostation_dolphin_initialize("anotherUser","Sys","bad")==0);
   assert(g_log_path==logfile && g_user_directory=="User");
   g_validated_system=cycle%2 ? "gc" : "wii";
   g_validated_game="game";
   g_running=true; uninitialized=false;
   g_jit_handshake=true; g_executable_probe=true;
   g_metal_surface=reinterpret_cast<void*>(uintptr_t{42});
   g_boot_language=3;
   assert(neostation_dolphin_initialize("User","Sys","overlap")==0);
   assert(g_log_path==logfile);
   assert(neostation_dolphin_stop(logfile.c_str())==1);
   assert(uninitialized && !g_running && !g_cleanup_started);
   assert(g_initialized && process_shutdown==0);
   assert(g_metal_surface==nullptr && g_validated_game.empty());
   assert(joins==cycle+1);
 }
 // An aborted launch has no running core. Cleanup remains safe and permits
 // another validated session without rebuilding the controller callbacks.
 assert(neostation_dolphin_initialize("User","Sys","failed")==1);
 assert(neostation_dolphin_stop("failed")==1);
 assert(neostation_dolphin_stop("failed")==1);
 assert(neostation_dolphin_initialize("User","Sys","next")==1);
 assert(ui_init==1 && controllers_init==1 && process_shutdown==0);
}
'''
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary)
            cpp=directory/'lifecycle.cpp'
            executable=directory/'lifecycle'
            cpp.write_text(harness)
            result=subprocess.run([compiler,'-std=c++17','-pthread',str(cpp),'-o',str(executable)],
                                  capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            result=subprocess.run([str(executable)],capture_output=True,text=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stderr)


if __name__ == '__main__':
    unittest.main()
