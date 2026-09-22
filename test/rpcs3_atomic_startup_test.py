#!/usr/bin/env python3
"""Exercise the materialized RPCS3 iOS JIT reservation with a Mach VM mock.

Run: python3 test/rpcs3_atomic_startup_test.py [materialized-rpcs3-root]
Before Core materialization, the hash-locked canonical patch supplies the
function. With a Core path, the materialized function supplies it instead.
Both cases compile its actual body rather than approximating its control flow.
"""

import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SOURCE = (Path(sys.argv.pop(1)).resolve() / "Utilities/JITIOS.cpp"
          if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None)


def canonical_patch_postimage(relative: str) -> str:
    patch = ROOT / "build-utils/rpcs3/embedded-core.patch"
    manifest = json.loads((ROOT / "build-utils/rpcs3/canonical-source.json").read_text())
    payload = patch.read_bytes()
    if hashlib.sha256(payload).hexdigest() != manifest["patch_sha256"]:
        raise ValueError("canonical RPCS3 patch checksum mismatch")
    section_header = f"diff --git a/{relative} b/{relative}\n"
    section = payload.decode().split(section_header, 1)[1].split("\ndiff --git ", 1)[0]
    # Reassemble the resulting lines of the file's unified-diff hunks.
    # Every line of reserve_arena_layout is a patch addition; its constants
    # are context/additions directly above the function.
    lines = []
    inside_hunk = False
    for line in section.splitlines():
        if line.startswith("@@ "):
            inside_hunk = True
        elif inside_hunk and line.startswith((" ", "+")):
            lines.append(line[1:])
    return "\n".join(lines)


def extract_function(source: str, signature: str) -> str:
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 1
    cursor = opening + 1
    while depth:
        if cursor >= len(source):
            raise ValueError(f"unterminated function {signature}")
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor]


def extract_constant(source: str, name: str) -> str:
    pattern = rf"^(?:inline\s+)?constexpr\s+[^;\n]+\s+{name}\s*=\s*[^;]+;"
    match = re.search(pattern, source, re.MULTILINE)
    if match is None:
        raise ValueError(f"missing arena layout constant {name}")
    return match.group()


CPP_PREAMBLE = r'''
#include <algorithm>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

using u8 = unsigned char;
using usz = std::size_t;
using vm_address_t = std::uintptr_t;
using vm_size_t = std::size_t;
using kern_return_t = int;

constexpr kern_return_t KERN_SUCCESS = 0;
constexpr kern_return_t KERN_INVALID_ADDRESS = 1;
using mach_port_t = int;
using mach_msg_type_number_t = unsigned;
using vm_region_info_t = int*;
struct vm_region_basic_info_data_64_t { int unused; };
constexpr int MACH_PORT_NULL = 0;
constexpr int VM_REGION_BASIC_INFO_COUNT_64 = 9;
constexpr int VM_REGION_BASIC_INFO_64 = 9;
int getpagesize() { return 16384; }
constexpr kern_return_t KERN_NO_SPACE = 3;
constexpr kern_return_t KERN_PROTECTION_FAILURE = 4;
constexpr kern_return_t KERN_RESOURCE_SHORTAGE = 5;
// Darwin VM_FLAGS_FIXED is zero: an address is fixed unless ANYWHERE is set.
constexpr int VM_FLAGS_FIXED = 0;
constexpr int VM_FLAGS_ANYWHERE = 1;
constexpr int VM_FLAGS_OVERWRITE = 0x4000;
constexpr int VM_PROT_NONE = 0;
constexpr int VM_MEMORY_APPLICATION_SPECIFIC_1 = 240;
#define VM_MAKE_TAG(tag) (static_cast<int>(static_cast<unsigned int>(tag) << 24))

struct allocation_call { vm_address_t address; vm_size_t size; int flags; };
struct protection_call { vm_address_t address; vm_size_t size; int protection; };
struct release_call { vm_address_t address; vm_size_t size; };

std::map<vm_address_t, vm_size_t> live;
std::vector<allocation_call> allocations;
std::vector<protection_call> protections;
std::vector<release_call> releases;
std::vector<std::string> diagnostics;
bool fail_allocation = false;
bool fail_protection = false;
bool relocate_success = false;
bool collide_on_allocate = false;
int region_queries = 0;
int ports_released = 0;

int mach_task_self() { return 42; }

void reset_mock()
{
    live.clear();
    allocations.clear();
    protections.clear();
    releases.clear();
    diagnostics.clear();
    fail_allocation = false;
    fail_protection = false;
    relocate_success = false;
    collide_on_allocate = false;
    region_queries = ports_released = 0;
}

kern_return_t vm_region_64(int task, vm_address_t* address, vm_size_t* size,
                           int flavor, vm_region_info_t, mach_msg_type_number_t*, mach_port_t* object)
{
    assert(task == 42 && flavor == VM_REGION_BASIC_INFO_64);
    ++region_queries;
    for (const auto& [base, length] : live)
    {
        if (base + length > *address)
        {
            *address = base;
            *size = length;
            *object = 7;
            return KERN_SUCCESS;
        }
    }
    return KERN_INVALID_ADDRESS;
}
int mach_port_deallocate(int task, mach_port_t object)
{
    assert(task == 42 && object == 7);
    ++ports_released;
    return 0;
}

kern_return_t vm_allocate(int task, vm_address_t* address, vm_size_t size, int flags)
{
    assert(task == 42);
    assert(address != nullptr);
    const vm_address_t requested = *address;
    allocations.push_back({requested, size, flags});
    if (collide_on_allocate)
    {
        collide_on_allocate = false;
        live.emplace(requested, getpagesize());
    }
    if (fail_allocation)
    {
        return KERN_RESOURCE_SHORTAGE;
    }
    const vm_address_t actual = requested + (relocate_success ? 0x4000000 : 0);
    for (auto it = live.begin(); it != live.end(); ++it)
    {
        const bool overlaps = actual < it->first + it->second && it->first < actual + size;
        if (overlaps)
        {
            if (!(flags & VM_FLAGS_OVERWRITE))
            {
                return KERN_NO_SPACE;
            }
            live.erase(it);
            break;
        }
    }
    live.emplace(actual, size);
    *address = actual;
    return KERN_SUCCESS;
}

kern_return_t vm_protect(int task, vm_address_t address, vm_size_t size,
                         bool set_maximum, int protection)
{
    assert(task == 42 && !set_maximum);
    protections.push_back({address, size, protection});
    assert(live.contains(address) && live.at(address) == size);
    return fail_protection ? KERN_PROTECTION_FAILURE : KERN_SUCCESS;
}

kern_return_t vm_deallocate(int task, vm_address_t address, vm_size_t size)
{
    assert(task == 42);
    releases.push_back({address, size});
    assert(live.contains(address) && live.at(address) == size);
    live.erase(address);
    return KERN_SUCCESS;
}

void emit_diagnostic(std::string message) noexcept
{
    diagnostics.push_back(std::move(message));
}
'''


CPP_SCENARIOS = r'''
void check_exact_next_candidate_preserves_occupied_range()
{
    reset_mock();
    constexpr vm_size_t size = 16 * 1024 * 1024;
    live.emplace(arena_address_begin, size); // Another mapping owns the first slot.
    u8* result = reserve_arena_layout(size, arena_address_begin,
                                      arena_address_begin + arena_address_step + size);
    assert(result == reinterpret_cast<u8*>(arena_address_begin + size));
    assert(allocations.size() == 1);
    assert(allocations[0].address == arena_address_begin + size);
    assert(region_queries == 2 && ports_released == 1);
    for (const allocation_call& call : allocations)
    {
        assert(call.size == size); // One whole candidate per Mach transaction.
        assert(call.flags == (VM_FLAGS_FIXED | jit_vm_tag));
        assert(!(call.flags & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)));
    }
    assert(live.size() == 2 && live.at(arena_address_begin) == size);
    assert(live.at(arena_address_begin + size) == size);
    assert(protections.size() == 1);
    assert(protections[0].address == arena_address_begin + size);
    assert(protections[0].size == size && protections[0].protection == VM_PROT_NONE);
    assert(releases.empty());
}

void check_kernel_error_leaves_no_reservation()
{
    reset_mock();
    constexpr vm_size_t size = 16 * 1024 * 1024;
    fail_allocation = true;
    assert(reserve_arena_layout(size, arena_address_begin,
                                arena_address_begin + size) == nullptr);
    assert(allocations.size() == 1 && allocations[0].size == size);
    assert(live.empty() && protections.empty() && releases.empty());
    assert(!diagnostics.empty());
    assert(diagnostics.back().find("kernel=" + std::to_string(KERN_RESOURCE_SHORTAGE))
           != std::string::npos);
}

void check_protection_error_releases_range_and_allows_retry()
{
    reset_mock();
    constexpr vm_size_t size = 16 * 1024 * 1024;
    fail_protection = true;
    assert(reserve_arena_layout(size, arena_address_begin,
                                arena_address_begin + size) == nullptr);
    assert(allocations.size() == 1 && protections.size() == 1);
    assert(protections[0].address == arena_address_begin);
    assert(protections[0].protection == VM_PROT_NONE);
    assert(releases.size() == 1 && releases[0].address == arena_address_begin);
    assert(releases[0].size == size && live.empty());
    fail_protection = false;
    assert(reserve_arena_layout(size, arena_address_begin,
                                arena_address_begin + size)
           == reinterpret_cast<u8*>(arena_address_begin));
    assert(live.size() == 1 && live.at(arena_address_begin) == size);
}

void check_unexpected_kernel_relocation_is_released()
{
    reset_mock();
    constexpr vm_size_t size = 16 * 1024 * 1024;
    relocate_success = true;
    assert(reserve_arena_layout(size, arena_address_begin,
                                arena_address_begin + size) == nullptr);
    assert(allocations.size() == 1 && protections.empty());
    assert(releases.size() == 1);
    assert(releases[0].address == arena_address_begin + arena_address_step);
    assert(releases[0].size == size && live.empty());
}

void check_fragmented_low_va_falls_back_to_nearby_data()
{
    using namespace rpcs3::ios::jit;
    reset_mock();
    constexpr vm_size_t code_size = 448 * mib;
    constexpr vm_size_t data_size = 256 * mib;
    const vm_address_t code_address = arena_address_begin;
    const vm_address_t obstacle = code_address + code_size;
    const vm_address_t data_address = obstacle + arena_address_step;
    const vm_address_t tail = data_address + data_size;
    // No 896 MiB contiguous window remains, but two nearby slots are free.
    live.emplace(obstacle, arena_address_step);
    live.emplace(tail, arena_address_end - tail);
    u8* data = nullptr;
    usz data_capacity = 0;
    u8* code = reserve_code_data_layout(code_size, data, data_capacity);
    assert(code == reinterpret_cast<u8*>(code_address));
    assert(data == reinterpret_cast<u8*>(data_address));
    assert(data_capacity == data_size);
    assert(reinterpret_cast<vm_address_t>(data) - reinterpret_cast<vm_address_t>(code)
           < 0x1'0000'0000);
    assert(live.size() == 4);
    assert(live.at(obstacle) == arena_address_step);
    assert(live.at(tail) == arena_address_end - tail);
    assert(live.at(code_address) == code_size && live.at(data_address) == data_size);
    assert(protections.size() == 2);
    assert(protections[0].address == code_address && protections[0].size == code_size);
    assert(protections[1].address == data_address && protections[1].size == data_size);
    assert(releases.empty());
    for (const allocation_call& call : allocations)
    {
        assert(call.flags == (VM_FLAGS_FIXED | jit_vm_tag));
        assert(!(call.flags & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)));
    }
}

void check_no_compatible_data_window_releases_code()
{
    using namespace rpcs3::ios::jit;
    reset_mock();
    constexpr vm_size_t code_size = 448 * mib;
    constexpr vm_size_t far_data_size = 256 * mib;
    const vm_address_t code_address = arena_address_begin;
    const vm_address_t obstacle = code_address + code_size;
    const vm_address_t far_data = code_address + 5 * 1024 * mib;
    const vm_address_t tail = far_data + far_data_size;
    live.emplace(obstacle, far_data - obstacle);
    live.emplace(tail, arena_address_end - tail);
    u8* data = reinterpret_cast<u8*>(1);
    usz data_capacity = 123;
    u8* code = reserve_code_data_layout(code_size, data, data_capacity);
    assert(code == nullptr && data == nullptr && data_capacity == 0);
    assert(protections.size() == 1 && protections[0].address == code_address);
    assert(releases.size() == 1);
    assert(releases[0].address == code_address && releases[0].size == code_size);
    assert(live.size() == 2);
    assert(live.at(obstacle) == far_data - obstacle);
    assert(live.at(tail) == arena_address_end - tail);
    for (const allocation_call& call : allocations)
    {
        assert(call.flags == (VM_FLAGS_FIXED | jit_vm_tag));
        assert(!(call.flags & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)));
    }
}

void check_page_aligned_window_lost_by_old_64mib_rounding()
{
    using namespace rpcs3::ios::jit;
    reset_mock();
    const vm_address_t start = arena_address_begin + getpagesize();
    const vm_address_t tail = start + 704 * mib;
    live.emplace(arena_address_begin, getpagesize());
    live.emplace(tail, arena_address_end - tail);
    u8* data = nullptr;
    usz data_capacity = 0;
    u8* code = reserve_code_data_layout(448 * mib, data, data_capacity);
    assert(code == reinterpret_cast<u8*>(start));
    assert(data == code + 448 * mib && data_capacity == 256 * mib);
    // Both slots are exactly owned; the surrounding mappings are untouched.
    assert(live.size() == 4);
    assert(live.at(start) == 448 * mib);
    assert(live.at(start + 448 * mib) == 256 * mib);
}

void check_standard_capacity_uses_available_virtual_space()
{
    using namespace rpcs3::ios::jit;
    reset_mock();
    const vm_address_t start = arena_address_begin + getpagesize();
    const vm_address_t obstacle = start + 384 * mib;
    const vm_address_t data_start = obstacle + getpagesize();
    const vm_address_t tail = data_start + 256 * mib;
    live.emplace(arena_address_begin, getpagesize());
    live.emplace(obstacle, getpagesize());
    live.emplace(tail, arena_address_end - tail);
    u8* data = nullptr;
    usz data_capacity = 0;
    usz capacity = 448 * mib;
    assert(reserve_capacity_layout(capacity, false, data, data_capacity)
           == reinterpret_cast<u8*>(start));
    assert(capacity == 384 * mib && data_capacity == 256 * mib);
    assert(data == reinterpret_cast<u8*>(data_start));
    assert(live.size() == 5);
    vm_deallocate(42, start, capacity);
    vm_deallocate(42, data_start, data_capacity);
    capacity = 512 * mib;
    assert(reserve_capacity_layout(capacity, true, data, data_capacity) == nullptr);
    assert(capacity == 512 * mib && data == nullptr && data_capacity == 0);
    assert(live.size() == 3); // Explicit expanded policy was not silently reduced.
}

void check_minimum_failure_and_concurrent_mapping_preserve_ownership()
{
    using namespace rpcs3::ios::jit;
    reset_mock();
    const vm_address_t tail = arena_address_begin + 256 * mib;
    live.emplace(tail, arena_address_end - tail);
    const auto original = live;
    u8* data = nullptr;
    usz data_capacity = 0;
    usz capacity = 448 * mib;
    assert(reserve_capacity_layout(capacity, false, data, data_capacity) == nullptr);
    assert(capacity == arena_min_capacity && data == nullptr && data_capacity == 0);
    assert(live == original); // The temporary code reservation was returned.
    assert(allocations.size() < 10 && region_queries < 100);

    reset_mock();
    collide_on_allocate = true;
    assert(reserve_arena_layout(16 * mib, arena_address_begin,
                               arena_address_begin + 16 * mib) == nullptr);
    assert(live.size() == 1 && live.at(arena_address_begin) == 16384);
    assert(protections.empty() && releases.empty());
    for (const auto& call : allocations)
        assert(!(call.flags & (VM_FLAGS_ANYWHERE | VM_FLAGS_OVERWRITE)));
}

int main()
{
    check_exact_next_candidate_preserves_occupied_range();
    check_kernel_error_leaves_no_reservation();
    check_protection_error_releases_range_and_allows_retry();
    check_unexpected_kernel_relocation_is_released();
    check_fragmented_low_va_falls_back_to_nearby_data();
    check_no_compatible_data_window_releases_code();
    check_page_aligned_window_lost_by_old_64mib_rounding();
    check_standard_capacity_uses_available_virtual_space();
    check_minimum_failure_and_concurrent_mapping_preserve_ownership();
    std::puts("PASS: atomic exact Mach JIT reservation, fragmented low VA and cleanup");
}
'''


class AtomicJitReservationTest(unittest.TestCase):
    def test_real_reservation_function_against_mach_vm_mock(self) -> None:
        source = (SOURCE.read_text() if SOURCE
                  else canonical_patch_postimage("Utilities/JITIOS.cpp"))
        policy = ((SOURCE.parent / "JITIOSLayoutPolicy.h").read_text() if SOURCE
                  else canonical_patch_postimage("Utilities/JITIOSLayoutPolicy.h"))
        constants = "\n".join(
            extract_constant(source, name)
            for name in (
                "jit_vm_tag", "arena_address_begin", "arena_address_end", "arena_address_step"
            )
        )
        policy_constants = "\n".join(
            extract_constant(policy, name)
            for name in ("mib", "arena_min_capacity", "arena_max_capacity",
                         "arena_capacity_step")
        )
        policy_constants = "namespace rpcs3::ios::jit {\n" + policy_constants + "\n}"
        functions = "\n\n".join(
            extract_function(source, name)
            for name in ("u8* reserve_arena_layout(", "u8* reserve_code_data_layout(",
                         "u8* reserve_capacity_layout(")
        )
        with tempfile.TemporaryDirectory(prefix="neostation-atomic-jit-") as directory:
            path = Path(directory)
            cpp = path / "atomic_jit_test.cpp"
            executable = path / "atomic_jit_test"
            cpp.write_text("\n\n".join((CPP_PREAMBLE, constants, policy_constants,
                                        functions, CPP_SCENARIOS)))
            subprocess.run(
                ["c++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-pedantic",
                 str(cpp), "-o", str(executable)],
                check=True, timeout=60,
            )
            completed = subprocess.run(
                [str(executable)], check=True, capture_output=True, text=True, timeout=15
            )
            self.assertIn("PASS: atomic exact Mach JIT reservation", completed.stdout)


if __name__ == "__main__":
    unittest.main()
