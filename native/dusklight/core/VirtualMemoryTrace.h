#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

// Read-only measurements. A hole between mappings is NOT proof that the kernel
// permits an allocation there. Never reserve/unmap anything from diagnostics.
struct NeoDusklightVMHoles {
  static constexpr uint64_t begin = 0x100000000ULL;
  static constexpr uint64_t end = 0x1000000000ULL;
  static constexpr uint64_t jitMinimum = 256ULL * 1024 * 1024;
  uint64_t cursor = begin, mapped = 0, largestHole = 0, secondLargestHole = 0;
  unsigned jitMinimumHoles = 0;
  void observeHole(uint64_t size) {
    if (size >= jitMinimum) ++jitMinimumHoles;
    if (size > largestHole) {
      secondLargestHole = largestHole;
      largestHole = size;
    } else if (size > secondLargestHole) {
      secondLargestHole = size;
    }
  }
  void observe(uint64_t address, uint64_t size) {
    const uint64_t stop = size > std::numeric_limits<uint64_t>::max() - address
        ? std::numeric_limits<uint64_t>::max() : address + size;
    if (!size || stop <= cursor || address >= end) return;
    const uint64_t start = std::max(cursor, address);
    observeHole(start - cursor);
    const uint64_t clippedStop = std::min(stop, end);
    mapped += clippedStop - start;
    cursor = clippedStop;
  }
  void finish() { observeHole(end - cursor); }
};

#ifdef __APPLE__
#include <mach/mach.h>
#include <cstdio>
#include <unistd.h>

inline void NeoDusklightTraceVM(FILE* file, double timestamp, const char* build, const char* phase) {
  if (!file) return;
  task_vm_info_data_t task{};
  mach_msg_type_number_t taskCount = TASK_VM_INFO_COUNT;
  const auto taskResult = task_info(mach_task_self(), TASK_VM_INFO,
      reinterpret_cast<task_info_t>(&task), &taskCount);
  NeoDusklightVMHoles holes;
  static_assert(sizeof(vm_address_t) == 8, "Dusklight requires the arm64 address space");
  vm_address_t cursor = NeoDusklightVMHoles::begin;
  unsigned regions = 0, written = 0;
  kern_return_t query = KERN_SUCCESS;
  bool complete = false;
  // Match RPCS3's top-level map: holes inside reserved submaps are not free
  // allocation ranges. Descending from depth zero at each leaf also revisited
  // the first leaf of a submap and truncated the previous diagnostic.
  while (cursor < NeoDusklightVMHoles::end && regions < 8192) {
    vm_address_t address = cursor;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info{};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    query = vm_region_64(mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (query == KERN_INVALID_ADDRESS || address >= NeoDusklightVMHoles::end) {
      complete = true;
      break;
    }
    if (query != KERN_SUCCESS || !size ||
        size > std::numeric_limits<uint64_t>::max() - address || address + size <= cursor) break;
    holes.observe(address, size);
    ++regions;
    if (written < 64 || size >= 1024 * 1024) {
      fprintf(file, "%.3f pid=%d build=%s vm_region phase=%s start=0x%llx size=%llu protection=%d\n",
          timestamp, getpid(), build, phase, static_cast<unsigned long long>(address),
          static_cast<unsigned long long>(size), info.protection);
      ++written;
    }
    cursor = address + size;
  }
  complete = complete || cursor >= NeoDusklightVMHoles::end;
  if (complete) holes.finish();
  fprintf(file, "%.3f pid=%d build=%s vm_summary phase=%s task_result=%d footprint=%llu virtual=%llu low_mapped=%llu largest_visible_hole=%llu second_largest_visible_hole=%llu jit_min_holes=%u jit_minimum=%llu regions=%u written=%u complete=%d query=%d topology=top_level cursor=0x%llx\n",
      timestamp, getpid(), build, phase, taskResult,
      static_cast<unsigned long long>(task.phys_footprint), static_cast<unsigned long long>(task.virtual_size),
      static_cast<unsigned long long>(holes.mapped), static_cast<unsigned long long>(holes.largestHole),
      static_cast<unsigned long long>(holes.secondLargestHole), holes.jitMinimumHoles,
      static_cast<unsigned long long>(NeoDusklightVMHoles::jitMinimum), regions, written, complete, query,
      static_cast<unsigned long long>(cursor));
  fflush(file);
}
#endif
