#pragma once
#include "Rpcs3ArenaLayout.h"
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_statistics.h>
#include <unistd.h>
#include <sstream>
#include <string>

namespace neostation::rpcs3::arena {
struct DarwinBackend {
  int protection_error = 0, cleanup_error = 0;
  bool cleanup_failed() const { return cleanup_error != 0; }
  int reserve(uint64_t address, uint64_t bytes) {
    vm_address_t actual = static_cast<vm_address_t>(address);
    int error = ::vm_allocate(mach_task_self(), &actual, static_cast<vm_size_t>(bytes),
        VM_FLAGS_FIXED | VM_MAKE_TAG(VM_MEMORY_APPLICATION_SPECIFIC_1));
    if (error) return error;
    if (actual != address) {
      cleanup_error = release(actual, bytes);
      return KERN_INVALID_ADDRESS;
    }
    error = ::vm_protect(mach_task_self(), actual, static_cast<vm_size_t>(bytes), false, VM_PROT_NONE);
    if (error) { protection_error = error; cleanup_error = release(actual, bytes); }
    return error;
  }
  int release(uint64_t address, uint64_t bytes) {
    const int error = ::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(address),
        static_cast<vm_size_t>(bytes));
    if (error) cleanup_error = error;
    return error;
  }
};
struct MapSnapshot {
  std::vector<Range> gaps;
  uint64_t largest_gap = 0, total_free = 0;
  size_t regions = 0;
  int kernel = 0;
};
inline MapSnapshot snapshot() {
  MapSnapshot map;
  uint64_t cursor = low;
  // A bounded VM traversal, not a speculative allocation / success stub.
  while (cursor < high && map.regions < 32768) {
    vm_address_t address = static_cast<vm_address_t>(cursor);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    int error = ::vm_region_64(mach_task_self(), &address, &size,
        VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) ::mach_port_deallocate(mach_task_self(), object);
    if (error != KERN_SUCCESS && error != KERN_INVALID_ADDRESS) { map.kernel = error; break; }
    uint64_t gap_end = error == KERN_INVALID_ADDRESS ? high : std::min(high, uint64_t(address));
    if (gap_end > cursor) {
      map.gaps.push_back({cursor, gap_end});
      map.largest_gap = std::max(map.largest_gap, gap_end - cursor);
      map.total_free += gap_end - cursor;
    }
    if (error == KERN_INVALID_ADDRESS || uint64_t(address) >= high) break;
    if (!size || uint64_t(address) + uint64_t(size) <= cursor) {
      map.kernel = KERN_INVALID_ADDRESS;
      break;
    }
    cursor = uint64_t(address) + uint64_t(size);
    ++map.regions;
  }
  if (map.regions == 32768) map.kernel = KERN_RESOURCE_SHORTAGE;
  return map;
}
struct Reservation {
  Layout layout;
  std::string code, detail;
  bool poisoned = false;
  bool acquire() {
    if (poisoned) { code = "RPCS3_VA_ROLLBACK_FAILED"; return false; }
    if (layout) return true;
    const auto map = snapshot();
    DarwinBackend backend;
    ReservationResult result;
    if (!map.kernel) result = reserve(map.gaps, uint64_t(::getpagesize()), backend);
    layout = result.layout;
    poisoned = !result.cleanup_ok || backend.cleanup_error != 0;
    code = layout ? "RPCS3_VA_RESERVED" : poisoned ? "RPCS3_VA_ROLLBACK_FAILED" :
        map.kernel ? "RPCS3_VA_MAP_QUERY_FAILED" : result.attempts ?
        "RPCS3_VA_KERNEL_RESERVATION_FAILED" : "RPCS3_VA_NO_COMPATIBLE_LAYOUT";
    std::ostringstream out;
    out << code << " codeBytes=" << code_bytes << " dataBytes=" << data_bytes
        << " budgetBytes=" << budget_bytes << " codeAddress=0x" << std::hex << layout.code
        << " dataAddress=0x" << layout.data << std::dec
        << " mapKernel=" << map.kernel << " reserveKernel=" << result.kernel
        << " protectKernel=" << backend.protection_error << " cleanupKernel=" << backend.cleanup_error
        << " attemptedAddress=0x" << std::hex << result.attempted_address << std::dec
        << " attemptedBytes=" << result.attempted_bytes << " attempts=" << result.attempts << " largestGapBytes=" << map.largest_gap
        << " totalFreeBytes=" << map.total_free << " regions=" << map.regions;
    // Include useful bounds without importing old-session logs or flooding every probe.
    size_t reported = 0;
    for (auto gap : map.gaps) {
      if (gap.end - gap.begin < 16 * mib || reported++ >= 32) continue;
      out << " gap=[0x" << std::hex << gap.begin << ",0x" << gap.end << ")" << std::dec;
    }
    detail = out.str();
    return bool(layout) && !poisoned;
  }
  bool verify_owned() {
    if (!layout || poisoned) return false;
    for (const auto range : {Range{layout.code, layout.code + code_bytes},
                            Range{layout.data, layout.data + data_bytes}}) {
      uint64_t cursor = range.begin;
      while (cursor < range.end) {
        vm_address_t address = static_cast<vm_address_t>(cursor);
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info = {};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        const int error = ::vm_region_64(mach_task_self(), &address, &size,
            VM_REGION_BASIC_INFO_64, reinterpret_cast<vm_region_info_t>(&info), &count, &object);
        if (object != MACH_PORT_NULL) ::mach_port_deallocate(mach_task_self(), object);
        if (error || address > cursor || !size || uint64_t(address) + size <= cursor ||
            info.protection != VM_PROT_NONE) {
          code = "RPCS3_VA_OWNERSHIP_CHANGED";
          std::ostringstream out;
          out << code << " address=0x" << std::hex << cursor << std::dec
              << " queryKernel=" << error << " protection=" << info.protection;
          detail = out.str();
          // An altered mapping is no longer proven ours: do not unmap it on abort.
          poisoned = true;
          return false;
        }
        cursor = uint64_t(address) + size;
      }
    }
    return true;
  }
  int discard() {
    if (poisoned) return KERN_INVALID_ADDRESS;
    DarwinBackend backend;
    const int error = release(layout, backend);
    if (error) poisoned = true;
    return error;
  }
};
} // namespace neostation::rpcs3::arena
