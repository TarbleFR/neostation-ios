#pragma once

#ifdef __cplusplus
#include <cstddef>

namespace neostation::rpcs3 {

// Do not try to reserve RPCS3's full virtual-memory layout before the Core.
//
// The previous preflight attempted to mmap the same 8 + 12 + 4 GiB regions
// that RPCS3 later owns itself. On iOS that is not an authoritative entitlement
// check: mmap(address, ...) treats the address as a hint unless the Core uses
// its own fixed-layout policy, ASLR can move the mapping, and the probe can
// therefore report a false failure even on devices where the standalone RPCS3
// IPA works correctly with the same SideStore signing profile.
//
// Build 229 already carries the required host entitlements inside Runner so the
// sideload signer can preserve them. The only authoritative test is now the
// real RPCS3 initialization performed immediately after the Universal JIT
// handshake. Keep this helper as a deliberately non-invasive compatibility
// preflight so older Dart/native call sites do not block the firmware flow.
template <class Map, class Unmap>
bool probe_virtual_layout(Map&&, Unmap&&) {
  static_assert(sizeof(void*) == 8, "RPCS3 requires a 64-bit address space");
  return true;
}

inline bool probe_virtual_layout() {
  static_assert(sizeof(void*) == 8, "RPCS3 requires a 64-bit address space");
  return true;
}

}  // namespace neostation::rpcs3
#endif
