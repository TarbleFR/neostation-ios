#pragma once

#include <algorithm>
#include <cstdint>
#include <limits>

// Read-only measurements. A hole between mappings is NOT proof that the kernel
// permits an allocation there. Never reserve/unmap anything from diagnostics.
struct NeoDusklightVMHoles {
  static constexpr uint64_t begin = 0x100000000ULL;
  static constexpr uint64_t end = 0x1000000000ULL;
  uint64_t cursor = begin, mapped = 0, largestHole = 0;
  void observe(uint64_t address, uint64_t size) {
    const uint64_t stop = size > std::numeric_limits<uint64_t>::max() - address
        ? std::numeric_limits<uint64_t>::max() : address + size;
    if (!size || stop <= cursor || address >= end) return;
    const uint64_t start = std::max(cursor, address);
    largestHole = std::max(largestHole, start - cursor);
    const uint64_t clippedStop = std::min(stop, end);
    mapped += clippedStop - start;
    cursor = clippedStop;
  }
  void finish() { largestHole = std::max(largestHole, end - cursor); }
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
  while (cursor < NeoDusklightVMHoles::end && regions < 4096) {
    vm_address_t address = cursor;
    vm_size_t size = 0;
    natural_t depth = 0;
    vm_region_submap_info_data_64_t info{};
    do {
      mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
      query = vm_region_recurse_64(mach_task_self(), &address, &size, &depth,
          reinterpret_cast<vm_region_recurse_info_t>(&info), &count);
      if (query != KERN_SUCCESS || !info.is_submap) break;
      ++depth;
    } while (depth < 64);
    if (query == KERN_INVALID_ADDRESS || address >= NeoDusklightVMHoles::end) {
      complete = true;
      break;
    }
    if (query != KERN_SUCCESS || info.is_submap || !size ||
        size > std::numeric_limits<uint64_t>::max() - address || address + size <= cursor) break;
    holes.observe(address, size);
    ++regions;
    if (written < 256) {
      fprintf(file, "%.3f pid=%d build=%s vm_region phase=%s start=0x%llx size=%llu tag=%u protection=%d resident_pages=%u\n",
          timestamp, getpid(), build, phase, static_cast<unsigned long long>(address),
          static_cast<unsigned long long>(size), info.user_tag, info.protection, info.pages_resident);
      ++written;
    }
    cursor = address + size;
  }
  complete = complete || cursor >= NeoDusklightVMHoles::end;
  if (complete) holes.finish();
  fprintf(file, "%.3f pid=%d build=%s vm_summary phase=%s task_result=%d footprint=%llu virtual=%llu low_mapped=%llu largest_visible_hole=%llu regions=%u written=%u complete=%d query=%d\n",
      timestamp, getpid(), build, phase, taskResult,
      static_cast<unsigned long long>(task.phys_footprint), static_cast<unsigned long long>(task.virtual_size),
      static_cast<unsigned long long>(holes.mapped), static_cast<unsigned long long>(holes.largestHole),
      regions, written, complete, query);
  fflush(file);
}
#endif
