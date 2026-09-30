#include "NeoSwapUsagePolicy.h"
#include <cassert>
#include <cstdio>

int main() {
  NeoSwapHostStats host = {};
  NeoSwapClientStats client = {};
  assert(NeoSwapUsage(0, &client, nullptr) == NeoSwapUsageStatus::unavailable);
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.reserved_virtual_bytes = 8ULL << 30;
  host.reservation_result = NEOSWAP_IO;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.reservation_result = NEOSWAP_OK;
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
  host.reserved_virtual_bytes = 0;
  host.reservation_result = NEOSWAP_MAPPING;
  host.donation_state = 1;
  host.donor_prepared_bytes = 64ULL << 20;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  host.donation_state = 2;
  assert(NeoSwapUsage(1ULL << 20, &client, &host) == NeoSwapUsageStatus::active);
  host.donation_state = 3;
  assert(NeoSwapUsage(0, &client, &host) == NeoSwapUsageStatus::unavailable);
  puts("PASS: actual usage takes precedence; zero distinguishes waiting/small/disabled/unbound/rejected/released; virtual reserve is never live RAM");
}
