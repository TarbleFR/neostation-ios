#include "NeoSwapUsagePolicy.h"
#include <cassert>
#include <cstdio>

int main() {
  for (auto title : {"BCES00510", "BCES00799", "BCUS98111", "BCJS37001", "BCAS25003", "BCKS15003"})
    assert(NeoSwapCPUBufferTitle(title));
  assert(!NeoSwapCPUBufferTitle("BLES00113") && !NeoSwapCPUBufferTitle("BCES00510-extra") &&
         !NeoSwapCPUBufferTitle(""));
  assert(NeoSwapFPSValid(60.0, 1));
  assert(NeoSwapFPSValid(0.0, 1));
  assert(NeoSwapFPSValid(120.0, 1));
  assert(!NeoSwapFPSValid(60.0, 0));
  assert(!NeoSwapFPSValid(-1.0, 1));
  assert(!NeoSwapFPSValid(NAN, 1));
  assert(!NeoSwapFPSValid(INFINITY, 1));
  {
    NeoSwapHostStats graphHost{};
    graphHost.owner_donated_live_bytes[NEOSWAP_RPCS3] = 51380224;
    graphHost.donor_prepared_bytes = 939524096;
    graphHost.reserved_virtual_bytes = 303038464;
    graphHost.relay_loan_live_bytes = 268435456;
    auto point = NeoSwapMemoryGraph(&graphHost, 1020788736, true, 2264317952);
    assert(point.allocatedValid && point.allocated == 1072168960);
    assert(point.residentValid && point.resident == 2264317952);
    // Host contribution: relay host loans plus donor loans, never guest pages.
    assert(point.hostLoansValid && point.hostLoans == 268435456 + 51380224);
    // Device RAM (7 October 2026): the resident counter merged with the
    // microprocess backing; the overlay draws this and the host contribution.
    assert(point.deviceRamValid && point.deviceRam == 2264317952ULL + 1072168960ULL);
    {
      const auto unmeasured = NeoSwapMemoryGraph(&graphHost, 1, false, 2264317952);
      assert(!unmeasured.allocatedValid && unmeasured.deviceRamValid && unmeasured.deviceRam == 2264317952ULL);
      assert(!NeoSwapMemoryGraph(&graphHost, 1020788736, true, 0).deviceRamValid);
      assert(NeoSwapMemoryGraph(&graphHost, 1020788736, true, UINT64_MAX).deviceRam == UINT64_MAX);
      const auto hostless = NeoSwapMemoryGraph(nullptr, 1, true, 7);
      assert(hostless.deviceRamValid && hostless.deviceRam == 7 && !hostless.allocatedValid);
    }
    assert(NeoSwapHostLoanBytes(&graphHost) == point.hostLoans && !NeoSwapHostLoanBytes(nullptr));
    assert(!NeoSwapMemoryGraph(nullptr, 1, true, 1).hostLoansValid);
    graphHost.relay_loan_live_bytes = UINT64_MAX;
    assert(NeoSwapHostLoanBytes(&graphHost) == UINT64_MAX);
    graphHost.relay_loan_live_bytes = 268435456;
    assert(NeoSwapDecimalGB(1000000000) == 1.0);
    assert(NeoSwapDecimalGB(500000000) == 0.5);
    // Lost creators/readiness must not hide allocations still owned by RPCS3.
    graphHost.donation_state = 3;
    assert(NeoSwapMemoryGraph(&graphHost, 1020788736, true, 1).allocated == point.allocated);
    assert(!NeoSwapMemoryGraph(nullptr, 1, true, 1).allocatedValid);
    assert(!NeoSwapMemoryGraph(&graphHost, 1, false, 1).allocatedValid);
    assert(!NeoSwapMemoryGraph(&graphHost, UINT64_MAX, true, 1).allocatedValid);
    graphHost = {};
    point = NeoSwapMemoryGraph(&graphHost, 0, true, 0);
    assert(point.allocatedValid && point.allocated == 0 && !point.residentValid);
    assert(!point.deviceRamValid && point.deviceRam == 0);
  }
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
  puts("PASS: device RAM merges resident pages with measured microprocess backing; live buffers take precedence; configured RPCS3 file owner or verified donors establish readiness with zero virtual reserve; missing, rejected, small, released and disabled states remain distinct");
}
