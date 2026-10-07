// Executes production preparation policy + production donor Pool. Darwin/XPC
// mappings are injected: this proves lifecycle/ownership, not iPhone residency.
#include "NeoSwapPreparation.h"
#include "../native/neoswap-donation/Pool.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <map>

namespace {
constexpr std::uint64_t MiB = 1024 * 1024, page = 16 * 1024;
std::map<void*, std::size_t> mappings;
bool refuse_mapping = false;
}
namespace neostation::donation {
Result availability() noexcept { return {}; }
Block::~Block() { (void)reset(); }
Result Block::reset() noexcept {
    if (address_) {
        assert(mappings.erase(data()) == 1);
        std::free(data());
    }
    address_ = bytes_ = entry_ = 0;
    return {};
}
Result Block::map_borrowed(std::uint32_t entry, std::size_t bytes, Block& out) noexcept {
    if (refuse_mapping) return {Stage::map_entry, 701};
    void* pointer = std::aligned_alloc(65536, bytes);
    assert(pointer);
    out.address_ = reinterpret_cast<std::uintptr_t>(pointer);
    out.bytes_ = bytes;
    out.entry_ = entry;
    mappings[pointer] = bytes;
    return {};
}
}
using namespace neostation;
using namespace neostation::donation;

static preparation::Observation observation(bool relay_ready = false, bool refused = false) {
    PoolSnapshot pool{};
    pool_snapshot(pool);
    return {pool.state == PoolState::verified, pool.donor_count, pool.prepared_bytes, relay_ready, refused};
}
static void verify(std::uint64_t epoch, std::uint64_t generation, std::uint64_t capacity) {
    Footprint ledger{};
    ledger.physical = ledger.nonvolatile = capacity;
    assert(pool_verify_donor(epoch, 0, generation, capacity, ledger, capacity, 0));
}
static void expect_no_loan(std::uint64_t bytes) {
    void* pointer = nullptr;
    std::uint64_t token = 0;
    assert(!pool_acquire(bytes, 65536, &pointer, &token));
    assert(!pointer && !token);
}

int main() {
    using preparation::Mode;
    preparation::Lifecycle lifecycle;
    assert(preparation::next_chunk(5ULL << 30, 5ULL << 30, page) == 16 * MiB);
    assert(preparation::next_chunk(5ULL << 30, 8 * MiB + 1, page) == 8 * MiB);
    assert(preparation::next_chunk(4 * MiB, 16 * MiB, page) == 4 * MiB);
    assert(!preparation::next_chunk(MiB, page - 1, page));
    assert(!preparation::next_chunk(MiB, MiB, 0));
    assert(lifecycle.begin(1, 100));
    assert(!lifecycle.begin(1, 200) && !lifecycle.begin(2, 200));
    assert(lifecycle.starts() == 1); // duplicate wake/timer do not reprepare
    assert(pool_campaign_begin(1, 256 * MiB));
    assert(pool_donor_begin(1, 0, 10, 12345));
    expect_no_loan(MiB); // a route, PID and requested capacity prove nothing
    assert(lifecycle.observe(1, 110, observation(true)) == Mode::warming);

    // A headroom-limited partial chunk is retained but unavailable until its
    // authenticated page/ledger proof is adopted into the production pool.
    assert(pool_adopt_donor(1, 0, 10, 0, 17, 8 * MiB));
    expect_no_loan(MiB);
    assert(lifecycle.observe(1, 120, observation()) == Mode::warming);
    verify(1, 10, 8 * MiB);
    assert(lifecycle.observe(1, 130, observation()) == Mode::partial);
    assert(lifecycle.first_prepared_ms() == 30 && lifecycle.observed_prepared());
    void* live = nullptr;
    std::uint64_t token = 0;
    assert(pool_acquire(MiB, 65536, &live, &token));
    static_cast<unsigned char*>(live)[0] = 91;
    assert(!lifecycle.finish(1, 1));
    assert(!pool_campaign_end(1));

    // Refused growth never discards the valid partial loan or restarts prep.
    refuse_mapping = true;
    assert(!pool_adopt_donor(1, 0, 10, 1, 18, 16 * MiB));
    assert(lifecycle.observe(1, 1700, observation(true, true)) == Mode::partial);
    assert(lifecycle.timed_out()); // seed deadline missed, gameplay did not wait
    assert(static_cast<unsigned char*>(live)[0] == 91);
    refuse_mapping = false;
    assert(pool_adopt_donor(1, 0, 10, 1, 18, 16 * MiB));
    verify(1, 10, 24 * MiB);
    assert(lifecycle.observe(1, 1900, observation(true)) == Mode::donors);
    assert(lifecycle.timed_out() && lifecycle.starts() == 1);
    assert(lifecycle.first_ready_ms() == 1800);

    // A demand larger than seed chunks needs one contiguous larger object.
    // No successful warmup or aggregate byte count may acknowledge it early.
    expect_no_loan(64 * MiB);
    assert(pool_adopt_donor(1, 0, 10, 2, 19, 64 * MiB));
    verify(1, 10, 88 * MiB);
    void* large = nullptr;
    std::uint64_t large_token = 0;
    assert(pool_acquire(64 * MiB, 65536, &large, &large_token));
    assert(pool_release(large_token));

    // Donor loss switches to a real relay backend only if it is verified.
    pool_donor_lost(1, 0, 10, 44);
    assert(lifecycle.observe(1, 1950, observation(true, true)) == Mode::relay_only);
    assert(lifecycle.observe(1, 2000, observation(false, true)) == Mode::ordinary);
    expect_no_loan(MiB);
    assert(static_cast<unsigned char*>(live)[0] == 91);
    assert(pool_release(token));
    assert(pool_campaign_end(1));
    assert(lifecycle.finish(1, 0));
    assert(mappings.empty());

    // Relaunch is a new campaign; late callbacks cannot resurrect the old one.
    assert(lifecycle.begin(2, 2200));
    assert(pool_campaign_begin(2, 256 * MiB));
    assert(pool_donor_begin(2, 0, 20, 12346));
    assert(lifecycle.observe(1, 2300, {true, 1, 88 * MiB, true, false}) == Mode::idle);
    assert(!pool_adopt_donor(1, 0, 10, 3, 20, 16 * MiB));
    assert(lifecycle.observe(2, 2500, observation(true)) == Mode::warming);
    assert(lifecycle.observe(2, 3700, observation(true)) == Mode::relay_only);
    assert(lifecycle.observe(2, 3750, observation(false)) == Mode::ordinary);
    assert(lifecycle.starts() == 2 && !lifecycle.observed_prepared());
    assert(pool_adopt_donor(2, 0, 20, 0, 21, 16 * MiB));
    verify(2, 20, 16 * MiB);
    assert(lifecycle.observe(2, 3800, observation()) == Mode::donors);
    assert(lifecycle.first_prepared_ms() == 1600);
    assert(pool_campaign_end(2));
    assert(lifecycle.finish(2, 0) && mappings.empty());
    assert(!lifecycle.begin(1, 4000));
    assert(lifecycle.begin(3, 4000));
    assert(lifecycle.observe(3, 4100, {true, 1, 16 * MiB, true, false}) == Mode::donors);
    assert(lifecycle.first_ready_ms() == 100 && !lifecycle.timed_out());
    // Losing a donor later is not a startup timeout; the actual refusal is
    // retained separately and ordinary/relay fallback still applies.
    assert(lifecycle.observe(3, 9000, {false, 0, 0, true, true}) == Mode::relay_only);
    assert(!lifecycle.timed_out());
    std::puts("PASS: production donor pool + preparation lifecycle: bounded chunks, partial proof, refusal, timeout, explicit fallback, contiguous large demand, duplicate start, retained loans, stale callbacks and relaunch; injected OS mappings, no iPhone/RAM claim");
}
