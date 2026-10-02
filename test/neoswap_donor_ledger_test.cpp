#include "DonorLedger.h"
#include <cassert>
#include <cstdio>
#include <initializer_list>
#include <limits>

using namespace neostation::donation;
constexpr std::uint64_t MiB = 1024 * 1024;
constexpr std::uint64_t page = 16 * 1024;

static Footprint ledger(std::uint64_t resident, std::uint64_t compressed) {
  Footprint result{};
  result.nonvolatile = resident;
  result.nonvolatile_compressed = compressed;
  return result;
}

static void expect(const Footprint& current, const Footprint& baseline,
    std::uint64_t capacity, std::uint64_t resident, std::uint64_t compressed,
    bool valid = true) {
  const auto measured = measured_ledger_delta(current, baseline, capacity);
  assert(measured.resident == resident);
  assert(measured.compressed == compressed);
  assert(measured.valid == valid);
}

int main() {
  constexpr std::uint64_t floor = 512 * MiB, reserve = 128 * MiB, quantum = 128 * MiB, limit = 5ULL << 30;
  assert(adaptive_donation_target(135266304, floor, reserve, quantum, limit) == floor);
  assert(adaptive_donation_target(354418688, floor, reserve, quantum, limit) == floor);
  assert(adaptive_donation_target(512 * MiB, floor, reserve, quantum, limit) == 640 * MiB);
  assert(adaptive_donation_target(4ULL << 30, floor, reserve, quantum, limit) == (4ULL << 30) + reserve);
  assert(adaptive_donation_target(limit - MiB, floor, reserve, quantum, limit) == limit);
  assert(adaptive_donation_target(UINT64_MAX, floor, reserve, quantum, limit) == limit);
  assert(adaptive_donation_target(0, floor, reserve, 0, limit) == 0);
  assert(adaptive_donation_target(0, floor, reserve, quantum, 0) == 0);
  assert(adaptive_donation_target(0, UINT64_MAX, UINT64_MAX, quantum, limit) == limit);
  // Build392 requested 480 MiB from a backend accepting at most 256 MiB.
  assert(valid_chunk_size(64 * MiB, page));
  assert(valid_chunk_size(max_chunk_bytes, page));
  assert(!valid_chunk_size(480 * MiB, page));
  assert(!valid_chunk_size(max_chunk_bytes + page, page));
  assert(!valid_chunk_size(MiB + 1, page));
  assert(!valid_chunk_size(0, page) && !valid_chunk_size(MiB, 0));
  assert(pending_headroom_budget(512 * MiB, 5ULL << 30, 128 * MiB, page) == 384 * MiB);
  assert(pending_headroom_budget(512 * MiB, 64 * MiB, 64 * MiB, page) == 0);
  assert(pending_headroom_budget(64 * MiB, 5ULL << 30, 128 * MiB, page) == 0);
  assert(pending_headroom_budget(UINT64_MAX, 5ULL << 30, UINT64_MAX, page) == 0);
  assert(pending_headroom_budget(5 * page + 1, UINT64_MAX, page, page) == 4 * page);
  assert(pending_headroom_budget(MiB, MiB, 0, 0) == 0);
  // The per-block limit does not cap the aggregate at 256 MiB.
  uint64_t aggregate = 0;
  for (unsigned n = 0; n < 20; ++n) {
    assert(valid_chunk_size(max_chunk_bytes, page));
    aggregate += max_chunk_bytes;
  }
  assert(aggregate == (5ULL << 30));
  // Actual device logs use a 32 KiB nonvolatile baseline and 1 MiB objects.
  // Compressing those baseline pages must not add fictitious donated pages.
  const auto deviceBaseline = ledger(2 * page, 0);
  expect(ledger(0, MiB + 2 * page), deviceBaseline, MiB, 0, MiB);
  expect(ledger(page, MiB + page), deviceBaseline, MiB, 0, MiB);
  expect(ledger(2 * page, MiB), deviceBaseline, MiB, 0, MiB);
  expect(ledger(MiB + 2 * page, 0), deviceBaseline, MiB, MiB, 0);
  expect(ledger(MiB / 2 + 2 * page, MiB / 2), deviceBaseline,
         MiB, MiB / 2, MiB / 2);
  // The reverse move, and a baseline-only move with no new pages.
  expect(ledger(MiB + 2 * page, 0), ledger(0, 2 * page), MiB, MiB, 0);
  expect(ledger(0, 2 * page), deviceBaseline, MiB, 0, 0);
  expect(ledger(2 * page, 0), ledger(0, 2 * page), MiB, 0, 0);

  // A real increase of even one page above the verified object is refused.
  expect(ledger(0, MiB + 3 * page), deviceBaseline, MiB, 0, MiB + page, false);
  expect(ledger(MiB + 3 * page, 0), deviceBaseline, MiB, MiB + page, 0, false);
  expect(ledger(MiB / 2 + 3 * page, MiB / 2), deviceBaseline,
         MiB, MiB / 2 + page, MiB / 2, false);
  // A new chunk must still independently add its pages. Migration of old
  // baseline pages neither creates a second chunk nor erases its increment.
  const auto beforeGrowth = ledger(2 * page, MiB);
  const auto afterGrowth = ledger(0, 2 * MiB + 2 * page);
  expect(afterGrowth, deviceBaseline, 2 * MiB, 0, 2 * MiB);
  expect(afterGrowth, beforeGrowth, MiB, 0, MiB);
  expect(beforeGrowth, beforeGrowth, MiB, 0, 0);

  const auto maximum = std::numeric_limits<std::uint64_t>::max();
  expect(ledger(maximum, 1), ledger(0, 0), maximum, 0, 0, false);
  expect(ledger(0, 0), ledger(maximum, 1), maximum, 0, 0, false);
  expect(ledger(maximum, 0), ledger(0, maximum), maximum, 0, 0);
  expect(ledger(maximum, 0), ledger(0, 1), maximum, maximum - 1, 0);
  expect(ledger(0, maximum), ledger(1, 0), maximum, 0, maximum - 1);
  expect(ledger(maximum, 0), ledger(0, 0), maximum, maximum, 0);
  expect(ledger(2 * page, 0), ledger(0, 0), 0, 2 * page, 0, false);

  // Exhaust all small process-ledger category changes. The sum must equal the
  // positive total increase, independently of the distribution between ledgers.
  for (std::uint64_t beforeResident = 0; beforeResident <= 16; ++beforeResident)
    for (std::uint64_t beforeCompressed = 0; beforeCompressed <= 16; ++beforeCompressed)
      for (std::uint64_t currentResident = 0; currentResident <= 16; ++currentResident)
        for (std::uint64_t currentCompressed = 0; currentCompressed <= 16; ++currentCompressed) {
          const auto beforeTotal = beforeResident + beforeCompressed;
          const auto currentTotal = currentResident + currentCompressed;
          const auto increase = currentTotal > beforeTotal ? currentTotal - beforeTotal : 0;
          for (const auto capacity : {std::uint64_t(0), increase, std::uint64_t(32)}) {
            const auto measured = measured_ledger_delta(ledger(currentResident, currentCompressed),
                ledger(beforeResident, beforeCompressed), capacity);
            assert(measured.resident + measured.compressed == increase);
            assert(measured.valid == (increase <= capacity));
          }
        }
  std::puts("PASS: baseline compression preserves measured totals; true excess and overflow are refused; new chunks still need independent ledger growth");
}
