#include "NeoSwapUsagePolicy.h"
#include <cassert>
#include <cstdio>

int main() {
  NeoSwapHostStats host = {};
  NeoSwapClientStats client = {};
  assert(!NeoSwapDonorMeasured(nullptr));
  assert(!NeoSwapDonorMeasured(&host));
  assert(NeoSwapUsage(0, &client, nullptr) == NeoSwapUsageStatus::unavailable);
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.reserved_virtual_bytes = 8ULL << 30;
  host.reservation_result = NEOSWAP_IO;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.reservation_result = NEOSWAP_OK;
  // A quota or an address-space count cannot establish allocator readiness.
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.file_ready_owner_mask = 1u << NEOSWAP_ARMSX2;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.file_ready_owner_mask = 1u << NEOSWAP_RPCS3;
  host.reserved_virtual_bytes = 0;
  host.reservation_result = NEOSWAP_MAPPING;
  // Zero VA is normal. The last operation's failure does not disable a
  // configured fallback owner; actual client counters describe that request.
  assert(NeoSwapUsage(0, nullptr, &host) == NeoSwapUsageStatus::clientUnavailable);
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::waiting);
  client.skipped_small = 123;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::small);
  client.missing_api = 1;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::clientUnavailable);
  client.disabled = 1;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::disabled);
  client.eligible_attempts = 1;
  client.failed_allocations = 1;
  client.last_result = NEOSWAP_IO;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::rejected);
  client.successful_allocations = 1;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::rejected);
  client.last_result = NEOSWAP_OK;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::released);
  assert(NeoSwapUsage(1ULL << 20, &client, &host) == NeoSwapUsageStatus::active);
  assert(NeoSwapUsage(1ULL << 20, nullptr, &host) == NeoSwapUsageStatus::active);
  assert(NeoSwapUsage(1ULL << 20, nullptr, nullptr) == NeoSwapUsageStatus::active);
  host.file_ready_owner_mask = 0;
  host.donation_state = 1;
  host.donor_prepared_bytes = 64ULL << 20;
  host.donor_count = 1;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.donation_state = 2;
  assert(NeoSwapDonorMeasured(&host));
  client = {};
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::waiting);
  assert(NeoSwapUsage(1ULL << 20, &client, &host) == NeoSwapUsageStatus::active);
  host.donor_count = 0;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.donor_count = 1;
  host.donor_prepared_bytes = 0;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.donor_prepared_bytes = 64ULL << 20;
  host.donation_state = 3;
  assert(!NeoSwapDonorMeasured(&host));
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  assert(NeoSwapUsage(1ULL << 20, &client, &host) == NeoSwapUsageStatus::active);
  host.file_ready_owner_mask = 1u << NEOSWAP_RPCS3;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::waiting);
  puts("PASS: live buffers take precedence; configured RPCS3 file owner or verified donors establish readiness with zero virtual reserve; missing, rejected, small, released and disabled states remain distinct");
}
