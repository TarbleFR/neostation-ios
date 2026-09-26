#pragma once

#include <cstdint>

namespace neokartpad {

// The pinned donor's InitializeDataSections has a process-lifetime guard.
// Memory::Init clears guest RAM on every entry, so the guard must be rearmed
// only after an orderly session has returned and Memory::Reset has completed.
inline bool RearmDonorDataSections(uint8_t* initialized) {
  if (!initialized || *initialized != 1) return false;
  *initialized = 0;
  return true;
}

}  // namespace neokartpad
