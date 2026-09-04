"""Regression tests for the generated Dolphin-only memory permission check.

The mock validates range/permission handling, not iOS runtime JIT support.
The real iPhoneOS API is compiled by the native core CI job.
"""
from __future__ import annotations

import importlib.util
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "dolphin_core_patch", ROOT / "build-utils/patch_dolphin_internal_core_v2.py"
)
assert SPEC and SPEC.loader
PATCH = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCH)
SOURCE = PATCH.BRIDGE_SOURCE


class DolphinMemoryPermissionsTest(unittest.TestCase):
    def test_uses_iphoneos_vm_api(self) -> None:
        self.assertNotIn("#import <mach/mach_vm.h>", SOURCE)
        self.assertNotIn("mach_vm_region(", SOURCE)
        self.assertIn("#import <mach/vm_map.h>", SOURCE)
        self.assertIn("vm_region_64(mach_task_self(),", SOURCE)
        self.assertIn("sizeof(vm_address_t) == sizeof(void*)", SOURCE)

    def test_requires_real_executable_and_writable_mappings(self) -> None:
        self.assertIn("HasMemoryPermissions(rx, 8, VM_PROT_READ | VM_PROT_EXECUTE)", SOURCE)
        self.assertIn("HasMemoryPermissions(rw, 8, VM_PROT_READ | VM_PROT_WRITE)", SOURCE)
        self.assertIn("value != 42", SOURCE)

    def test_range_permissions_and_port_release(self) -> None:
        compiler = shutil.which("clang++") or shutil.which("g++")
        if not compiler:
            self.skipTest("A C++ compiler is required for the VM range mock")
        start = SOURCE.index("bool HasMemoryPermissions(")
        end = SOURCE.index("\nbool SelectRegionalIPL(", start)
        function = SOURCE[start:end]
        harness = r'''
#include <cassert>
#include <cstddef>
#include <cstdint>
using size_t = std::size_t;
using vm_address_t = std::uintptr_t;
using vm_size_t = std::uintptr_t;
using vm_prot_t = int;
using mach_msg_type_number_t = unsigned;
using mach_port_t = unsigned;
using kern_return_t = int;
using vm_region_info_t = int*;
constexpr int VM_REGION_BASIC_INFO_64 = 9;
constexpr unsigned VM_REGION_BASIC_INFO_COUNT_64 = 9;
constexpr unsigned MACH_PORT_NULL = 0;
constexpr int KERN_SUCCESS = 0;
struct vm_region_basic_info_data_64_t { int protection; };
static vm_address_t base = 0x1000;
static vm_size_t extent = 0x1000;
static unsigned returned_count = VM_REGION_BASIC_INFO_COUNT_64;
static int status = KERN_SUCCESS, protection = 5, releases = 0;
static unsigned calls = 0;
unsigned mach_task_self() { return 1; }
int mach_port_deallocate(unsigned task, unsigned port) {
  assert(task == 1 && port == 42); ++releases; return 0;
}
int vm_region_64(unsigned task, vm_address_t* address, vm_size_t* size,
                 int flavor, vm_region_info_t info, unsigned* count, unsigned* port) {
  assert(task == 1 && flavor == VM_REGION_BASIC_INFO_64);
  assert(*count == VM_REGION_BASIC_INFO_COUNT_64);
  ++calls; *address = base; *size = extent; *count = returned_count;
  reinterpret_cast<vm_region_basic_info_data_64_t*>(info)->protection = protection;
  *port = 42; return status;
}
'''
        harness += function + r'''
int main() {
  auto ptr = [](std::uintptr_t value) { return reinterpret_cast<void*>(value); };
  assert(!HasMemoryPermissions(nullptr, 8, 5));
  assert(!HasMemoryPermissions(ptr(0x1000), 0, 5));
  assert(calls == 0);
  assert(HasMemoryPermissions(ptr(0x1000), 8, 5));
  assert(HasMemoryPermissions(ptr(0x1ff8), 8, 5));
  assert(!HasMemoryPermissions(ptr(0x1ffc), 8, 5));
  assert(!HasMemoryPermissions(ptr(0x0ff0), 8, 5));
  assert(!HasMemoryPermissions(ptr(0x1000), 0x1001, 5));
  protection = 1; assert(!HasMemoryPermissions(ptr(0x1000), 8, 5));
  protection = 3; assert(HasMemoryPermissions(ptr(0x1000), 8, 3));
  status = 1; assert(!HasMemoryPermissions(ptr(0x1000), 8, 3));
  status = 0; returned_count = 0;
  assert(!HasMemoryPermissions(ptr(0x1000), 8, 3));
  assert(releases == static_cast<int>(calls));
}
'''
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "memory_permissions_test.cpp"
            binary = Path(directory) / "memory_permissions_test"
            source.write_text(harness, encoding="utf-8")
            subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-Werror",
                            str(source), "-o", str(binary)], check=True, timeout=30)
            subprocess.run([str(binary)], check=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
