// Host allocator behavior with injected mapping ownership, NOT Darwin/iPhone
// residency evidence. The production Pool.cpp is linked unchanged into this test.
#include "../native/neoswap-donation/Pool.h"
#include <cassert>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <map>
#include <random>
#include <vector>
#include <algorithm>
#include <thread>

namespace {
constexpr std::size_t KiB = 1024, MiB = 1024 * KiB;
std::map<void*, void*> mappings;
bool fail_cleanup = false, check_busy_on_cleanup = true;
}
namespace neostation::donation {
Result availability() noexcept { return {}; }
Block::~Block() { (void)reset(); }
Result Block::reset() noexcept {
  if (address_) {
  if (check_busy_on_cleanup) {
    check_busy_on_cleanup = false;
    // Production collection owns the pool mutex across the slow unmap callback.
    // A concurrent emulator request must return before this callback finishes.
    std::thread requester([] {
      void* pointer = reinterpret_cast<void*>(1); std::uint64_t token = 42;
      const auto result = pool_acquire(64 * KiB, 64 * KiB, &pointer, &token);
      assert(result.stage == Stage::pool_busy && !pointer && !token);
    });
    requester.join();
  }

    if (fail_cleanup) { fail_cleanup = false; return {Stage::unmap, 701}; }
    auto found = mappings.find(data());
    assert(found != mappings.end());
    std::free(found->second); mappings.erase(found);
  }
  address_ = bytes_ = entry_ = 0;
  return {};
}
Result Block::map_borrowed(std::uint32_t entry, std::size_t bytes, Block& out) noexcept {
  // Deliberately page-aligned but NOT 64-KiB-aligned, as an iPhone map can be.
  void* base = std::aligned_alloc(64 * KiB, (bytes + 128 * KiB - 1) / (64 * KiB) * (64 * KiB));
  if (!base) return {Stage::map_entry, 702};
  void* address = static_cast<unsigned char*>(base) + 16 * KiB;
  out.address_ = reinterpret_cast<std::uintptr_t>(address);
  out.bytes_ = bytes; out.entry_ = entry;
  mappings[address] = base;
  return {};
}
}
using namespace neostation::donation;
struct Live { std::uint64_t token; unsigned char* pointer; std::size_t bytes; unsigned char tag; };
std::vector<Live> live;
static void verify() {
  std::uint64_t bytes = 0;
  for (const auto& item : live) {
    assert(item.pointer[0] == item.tag && item.pointer[item.bytes - 1] == item.tag);
    bytes += item.bytes;
  }
  PoolSnapshot snapshot{}; pool_snapshot(snapshot);
  assert(snapshot.live_blocks == live.size() && snapshot.live_bytes == bytes);
}
static void adopt(std::uint64_t epoch, unsigned index, unsigned chunk, unsigned port, std::size_t total) {
  assert(pool_adopt_donor(epoch, index, epoch, chunk, port, 128 * MiB));
  Footprint measured{}; measured.physical = measured.nonvolatile = total;
  assert(pool_verify_donor(epoch, index, epoch, total, measured, total, 0));
}
static bool acquire(std::size_t bytes, std::size_t alignment) {
  void* output = nullptr; std::uint64_t token = 0;
  const auto result = pool_acquire(bytes, alignment, &output, &token);
  if (!result) { assert(!output && !token); return false; }
  assert(token && reinterpret_cast<std::uintptr_t>(output) % alignment == 0);
  const auto start = reinterpret_cast<std::uintptr_t>(output), end = start + bytes;
  for (const auto& old : live) {
    const auto other = reinterpret_cast<std::uintptr_t>(old.pointer);
    assert(end <= other || start >= other + old.bytes);
    assert(token != old.token);
  }
  const auto tag = static_cast<unsigned char>(token % 251 + 1);
  auto pointer = static_cast<unsigned char*>(output);
  pointer[0] = pointer[bytes - 1] = tag;
  live.push_back({token, pointer, bytes, tag});
  return true;
}
static void release(std::size_t index) {
  verify();
  const auto token = live[index].token;
  assert(pool_release(token));
  assert(pool_release(token).stage == Stage::pool_not_owned);
  live.erase(live.begin() + index);
  verify();
}
int main() {
  // 1024 slots across two entries, head/middle/tail holes and 64 KiB alignment.
  assert(pool_campaign_begin(1, 512 * MiB));
  assert(pool_donor_begin(1, 0, 1, 12345));
  adopt(1, 0, 0, 17, 128 * MiB);
  adopt(1, 0, 1, 18, 256 * MiB);
  for (unsigned i = 0; i < 1024; ++i) assert(acquire(128 * KiB, 64 * KiB));
  assert(!acquire(64 * KiB, 64 * KiB));
  for (unsigned i = 0; i < 170; ++i) { release(0); release(live.size() / 2); release(live.size() - 1); }
  std::mt19937 random(395);
  for (unsigned i = 0; i < 3000; ++i) {
    if (!live.empty() && (random() % 3 == 0 || live.size() == 1024)) release(random() % live.size());
    else (void)acquire((1 + random() % 8) * 16 * KiB, std::size_t(1) << (random() % 17));
    verify();
  }
  assert(pool_campaign_end(1).stage == Stage::pool_unready);
  pool_donor_lost(1, 0, 1, 9);
  assert(pool_collect_lost());
  assert(!acquire(16 * KiB, 16 * KiB));
  verify(); // Active loans survive donor loss, collector never releases them.
  assert(!pool_donor_restartable(1, 0));
  while (!live.empty()) release(random() % live.size());
  fail_cleanup = true;
  assert(pool_collect_lost().stage == Stage::unmap);
  assert(pool_collect_lost());
  assert(pool_donor_restartable(1, 0));
  assert(pool_campaign_end(1) && mappings.empty());
  // A new campaign/entry must never inherit an old list head or token.
  assert(pool_campaign_begin(2, 128 * MiB));
  assert(pool_donor_begin(2, 0, 2, 12346));
  adopt(2, 0, 0, 19, 128 * MiB);
  for (unsigned i = 0; i < 128; ++i) assert(acquire(64 * KiB, 64 * KiB));
  while (!live.empty()) release(live.size() / 2);
  assert(pool_campaign_end(2) && mappings.empty());
  puts("PASS: production pool nonblocking acquisition during cleanup, 1024-slot exhaustion, fragmented gap reuse, alignment, data isolation, stale tokens, donor loss, failed cleanup and campaign reuse; injected OS, no physical-RAM claim");
}
