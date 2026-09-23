#pragma once

#include "Rpcs3EarlyAddressSpaceEscrowPolicy.h"

#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_statistics.h>
#include <unistd.h>

#include <algorithm>
#include <sstream>
#include <string>
#include <vector>

namespace neostation::rpcs3::early_escrow {

struct DarwinBackend {
  int protection_error = 0;
  int cleanup_error = 0;

  bool cleanup_failed() const { return cleanup_error != 0; }

  int reserve(uint64_t address, uint64_t bytes) {
    vm_address_t actual = static_cast<vm_address_t>(address);
    int error = ::vm_allocate(
        mach_task_self(), &actual, static_cast<vm_size_t>(bytes),
        VM_FLAGS_FIXED | VM_MAKE_TAG(VM_MEMORY_APPLICATION_SPECIFIC_1));
    if (error) return error;
    if (actual != address) {
      cleanup_error = release(actual, bytes);
      return KERN_INVALID_ADDRESS;
    }
    error = ::vm_protect(mach_task_self(), actual,
                         static_cast<vm_size_t>(bytes), false, VM_PROT_NONE);
    if (error) {
      protection_error = error;
      cleanup_error = release(actual, bytes);
    }
    return error;
  }

  int release(uint64_t address, uint64_t bytes) {
    const int error = ::vm_deallocate(mach_task_self(),
                                      static_cast<vm_address_t>(address),
                                      static_cast<vm_size_t>(bytes));
    if (error) cleanup_error = error;
    return error;
  }
};

struct MapSnapshot {
  std::vector<Range> gaps;
  uint64_t largest_gap = 0;
  uint64_t total_free = 0;
  size_t regions = 0;
  int kernel = 0;
};

inline MapSnapshot snapshot() {
  MapSnapshot map;
  uint64_t cursor = low;
  while (cursor < high && map.regions < 32768) {
    vm_address_t address = static_cast<vm_address_t>(cursor);
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info = {};
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    const int error = ::vm_region_64(
        mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
        reinterpret_cast<vm_region_info_t>(&info), &count, &object);
    if (object != MACH_PORT_NULL) {
      ::mach_port_deallocate(mach_task_self(), object);
    }
    if (error != KERN_SUCCESS && error != KERN_INVALID_ADDRESS) {
      map.kernel = error;
      break;
    }

    const uint64_t gap_end =
        error == KERN_INVALID_ADDRESS
            ? high
            : std::min(high, static_cast<uint64_t>(address));
    if (gap_end > cursor) {
      map.gaps.push_back({cursor, gap_end});
      map.largest_gap = std::max(map.largest_gap, gap_end - cursor);
      map.total_free += gap_end - cursor;
    }
    if (error == KERN_INVALID_ADDRESS ||
        static_cast<uint64_t>(address) >= high) {
      break;
    }
    if (!size || static_cast<uint64_t>(address) + size <= cursor) {
      map.kernel = KERN_INVALID_ADDRESS;
      break;
    }
    cursor = static_cast<uint64_t>(address) + size;
    ++map.regions;
  }
  if (map.regions == 32768) map.kernel = KERN_RESOURCE_SHORTAGE;
  return map;
}

enum class EscrowState {
  empty,
  held,
  handed_off,
  failed,
  poisoned,
};

class EarlyAddressSpaceEscrow {
 public:
  EarlyAddressSpaceEscrow() = default;
  EarlyAddressSpaceEscrow(const EarlyAddressSpaceEscrow&) = delete;
  EarlyAddressSpaceEscrow& operator=(const EarlyAddressSpaceEscrow&) = delete;

  ~EarlyAddressSpaceEscrow() {
    if (state_ == EscrowState::held) {
      DarwinBackend backend;
      (void)early_escrow::release(layout_, backend);
    }
  }

  bool acquire() {
    if (state_ == EscrowState::held) return true;
    if (state_ != EscrowState::empty) return false;

    const MapSnapshot map = snapshot();
    DarwinBackend backend;
    ReservationResult result;
    if (!map.kernel) {
      result = early_escrow::reserve(
          map.gaps, static_cast<uint64_t>(::getpagesize()), backend);
    }
    layout_ = result.layout;
    if (layout_ && result.cleanup_ok && !backend.cleanup_error) {
      state_ = EscrowState::held;
    } else if (!result.cleanup_ok || backend.cleanup_error) {
      state_ = EscrowState::poisoned;
    } else {
      state_ = EscrowState::failed;
    }

    std::ostringstream out;
    out << marker << " status=" << status()
        << " codeBytes=" << layout_.code_bytes
        << " dataBytes=" << data_bytes << " codeAddress=0x" << std::hex
        << layout_.code << " dataAddress=0x" << layout_.data << std::dec
        << " contiguous=" << (layout_.contiguous ? 1 : 0)
        << " mapKernel=" << map.kernel
        << " reserveKernel=" << result.kernel
        << " protectKernel=" << backend.protection_error
        << " cleanupKernel=" << backend.cleanup_error
        << " attempts=" << result.attempts
        << " attemptedAddress=0x" << std::hex
        << result.attempted_address << std::dec
        << " attemptedBytes=" << result.attempted_bytes
        << " largestGapBytes=" << map.largest_gap
        << " totalFreeBytes=" << map.total_free
        << " regions=" << map.regions;
    detail_ = out.str();
    return state_ == EscrowState::held;
  }

  bool active() const { return state_ == EscrowState::held; }
  const char* status() const {
    switch (state_) {
      case EscrowState::empty:
        return "empty";
      case EscrowState::held:
        return "held";
      case EscrowState::handed_off:
        return "handed_off";
      case EscrowState::failed:
        return "failed";
      case EscrowState::poisoned:
        return "poisoned";
    }
    return "unknown";
  }
  const std::string& detail() const { return detail_; }

  // On success, this function performs no allocation after vm_deallocate.
  // The caller must enter rpcs3_ios_initialize as its very next operation.
  bool release_for_core() {
    if (state_ != EscrowState::held || !verify_owned()) return false;
    DarwinBackend backend;
    const int error = early_escrow::release(layout_, backend);
    if (error || backend.cleanup_error) {
      state_ = EscrowState::poisoned;
      return false;
    }
    state_ = EscrowState::handed_off;
    return true;
  }

 private:
  bool verify_owned() {
    const std::array<Range, 2> ranges = {
        Range{layout_.code, layout_.code + layout_.code_bytes},
        Range{layout_.data, layout_.data + data_bytes},
    };
    for (const Range range : ranges) {
      uint64_t cursor = range.begin;
      while (cursor < range.end) {
        vm_address_t address = static_cast<vm_address_t>(cursor);
        vm_size_t size = 0;
        vm_region_basic_info_data_64_t info = {};
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        const int error = ::vm_region_64(
            mach_task_self(), &address, &size, VM_REGION_BASIC_INFO_64,
            reinterpret_cast<vm_region_info_t>(&info), &count, &object);
        if (object != MACH_PORT_NULL) {
          ::mach_port_deallocate(mach_task_self(), object);
        }
        if (error || address > cursor || !size ||
            static_cast<uint64_t>(address) + size <= cursor ||
            info.protection != VM_PROT_NONE) {
          state_ = EscrowState::poisoned;
          return false;
        }
        cursor = static_cast<uint64_t>(address) + size;
      }
    }
    return true;
  }

  Layout layout_;
  EscrowState state_ = EscrowState::empty;
  std::string detail_;
};

}  // namespace neostation::rpcs3::early_escrow
