#!/usr/bin/env python3
"""Run the actual Core initialization prefix with fault-injected native steps.

The prefix ends at Emu initialization; that unrelated subsystem is not mocked.
The actual detach function and lifecycle failure transition are also compiled.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from rpcs3_atomic_startup_test import canonical_patch_postimage, extract_function, SOURCE

PREAMBLE = r'''
#include <cassert>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <vector>
using u64 = unsigned long long;
using usz = std::size_t;
enum rpcs3_ios_status { RPCS3_IOS_OK, RPCS3_IOS_INVALID_ARGUMENT,
    RPCS3_IOS_INVALID_STATE, RPCS3_IOS_JIT_UNAVAILABLE, RPCS3_IOS_JIT_MAPPING_FAILED };
enum rpcs3_ios_state { RPCS3_IOS_STATE_UNINITIALIZED, RPCS3_IOS_STATE_INITIALIZING,
    RPCS3_IOS_STATE_READY, RPCS3_IOS_STATE_FAILED };
struct rpcs3_ios_config { const char* application_support_path; const char* cache_path;
    unsigned expanded_jit_arena; };
std::vector<std::string> events;
std::string failure_stage;
std::string error;
int listeners = 0;
bool universal = true;
bool issue_command = true;
bool step(const char* name) { events.emplace_back(name); return failure_stage != name; }
void emit_diagnostic(std::string) noexcept {}
void emit_jit_diagnostic(const char*) noexcept {}
void emit_log(int, std::string) {}
void set_error(std::string value) { error = std::move(value); }
namespace fmt { template <typename T> std::string format(const char* text, T) { return text; } }
namespace fs {
bool set_config_dir(const char*) { return step("paths"); }
bool set_cache_dir(const char*) { return true; }
}
struct callback_log_listener {};
namespace logs { struct listener { static void add(callback_log_listener*) { ++listeners; } }; }
std::unique_ptr<callback_log_listener> g_log_listener;
std::mutex g_api_mutex;
bool g_initialization_attempted = false;
std::string g_application_support_path, g_cache_path;
rpcs3_ios_config g_config{};
rpcs3_ios_status validate_config(const rpcs3_ios_config*) { return RPCS3_IOS_OK; }
namespace rpcs3::ios::jit {
enum class arena_backend { legacy_debugger, universal_mirrored };
constexpr u64 command_detach = 0;
arena_backend current_backend() { return universal ? arena_backend::universal_mirrored : arena_backend::legacy_debugger; }
u64 protocol_call(u64 command, const void* address, usz size, bool* issued) {
    assert(command == 0 && !address && !size);
    events.emplace_back("detach"); *issued = issue_command; return 0;
}
void set_diagnostic_callback(void(*)(const char*) noexcept) {}
const char* last_error() { return "original mapping error"; }
bool is_ready() { return step("ready"); }
bool prepare_arena(unsigned) { return step("arena"); }
bool finish_debugger_session() noexcept;
bool seal_arena() { return step("seal") && finish_debugger_session(); }
}
namespace asmjit { bool initialize_global_runtime() { return step("runtime"); } }
bool ppu_initialize_static_trampolines(std::string&) { return step("ppu"); }
namespace ppu_function_manager { bool initialize_ghc_trampolines(std::string&) { return step("hle"); } }
namespace spu_runtime { bool initialize_static_trampolines(std::string&) { return step("spu"); } }
'''
SCENARIOS = r'''
void reset(const char* fail) {
    events.clear(); failure_stage = fail; error.clear(); listeners = 0;
    g_lifecycle = {}; g_initialization_attempted = false; g_log_listener.reset();
    universal = true; issue_command = true;
}
int main() {
    const rpcs3_ios_config config{"/data", "/cache", 0};
    for (const char* stage : {"paths", "ready", "arena", "runtime", "ppu", "hle", "spu", "seal"}) {
        reset(stage);
        assert(rpcs3_ios_initialize(&config) != RPCS3_IOS_OK);
        assert(events.back() == "detach");
        assert(error.find("original mapping error") != std::string::npos || failure_stage == "paths");
        const bool early = failure_stage == "paths" || failure_stage == "ready" || failure_stage == "arena";
        assert(g_initialization_attempted == !early);
        assert(g_lifecycle.state() == (early ? RPCS3_IOS_STATE_UNINITIALIZED : RPCS3_IOS_STATE_FAILED));
        const int before = listeners;
        failure_stage.clear(); events.clear();
        const auto result = rpcs3_ios_initialize(&config);
        if (early) {
            assert(result == RPCS3_IOS_OK);
            assert(listeners == 1); // No duplicate/dangling callback listener.
            assert(events.back() == "detach");
        } else {
            assert(result == RPCS3_IOS_INVALID_STATE && events.empty());
            assert(listeners == before); // Partially constructed runtime cannot retry.
        }
    }
    reset("");
    assert(rpcs3_ios_initialize(&config) == RPCS3_IOS_OK);
    const auto done = events;
    assert(rpcs3_ios_initialize(&config) == RPCS3_IOS_INVALID_STATE);
    assert(events == done); // No implicit second initialization.
    reset(""); universal = false;
    assert(rpcs3::ios::jit::finish_debugger_session() && events.empty());
    universal = true; issue_command = false;
    assert(!rpcs3::ios::jit::finish_debugger_session());
}
'''

class FailedStartupTest(unittest.TestCase):
    def test_actual_native_failure_paths(self):
        def source(relative):
            return ((SOURCE.parent.parent / relative).read_text() if SOURCE
                    else canonical_patch_postimage(relative))
        api = source('rpcs3/ios/RPCS3IOS.cpp')
        jit = source('Utilities/JITIOS.cpp')
        contract = source('rpcs3/ios/RPCS3IOSContract.h')
        initialize = api[api.index('extern "C" rpcs3_ios_status rpcs3_ios_initialize('):]
        prefix = initialize.split('\n\ttry\n', 1)[0] + '\n g_lifecycle.finish_initialize(true); return RPCS3_IOS_OK;\n}\n'
        finish = extract_function(contract, 'void finish_initialize(')
        lifecycle = '''struct lifecycle {
 rpcs3_ios_state m_state = RPCS3_IOS_STATE_UNINITIALIZED;
 rpcs3_ios_state state() const { return m_state; }
 rpcs3_ios_status begin_initialize() {
   if (m_state != RPCS3_IOS_STATE_UNINITIALIZED) return RPCS3_IOS_INVALID_STATE;
   m_state = RPCS3_IOS_STATE_INITIALIZING; return RPCS3_IOS_OK;
 }
''' + finish + '\n} g_lifecycle;\n'
        detach = 'namespace rpcs3::ios::jit {\n' + extract_function(jit, 'bool finish_debugger_session(') + '\n}'
        with tempfile.TemporaryDirectory() as directory:
            cpp = Path(directory) / 'failure.cpp'
            exe = Path(directory) / 'failure'
            cpp.write_text('\n'.join((PREAMBLE, lifecycle, detach, prefix, SCENARIOS)))
            subprocess.run(['c++', '-std=c++20', '-Wall', '-Wextra', '-Werror', str(cpp), '-o', str(exe)], check=True, timeout=60)
            subprocess.run([str(exe)], check=True, timeout=10)

if __name__ == '__main__':
    unittest.main()
