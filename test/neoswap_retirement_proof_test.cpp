// Exercises the same bounded drain used by the native Vulkan proof against the
// actual host broker. Donor mappings are injected; this is not residency proof.
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include "Donation/RetirementProof.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <vector>
#include <unistd.h>

namespace fixture {
constexpr uint64_t KiB = 1024, MiB = 1024 * KiB;
bool fail_once = false, hold_releases = false;
uint64_t serial = 0;
struct Loan { void* pointer; uint64_t bytes; };
std::map<uint64_t, Loan> live;
}
namespace neostation::donation {
void pool_snapshot(PoolSnapshot& out) noexcept {
    out = {}; out.state = PoolState::verified; out.prepared_bytes = 64 * fixture::MiB; out.donor_count = 1;
    for (const auto& [token, loan] : fixture::live) { (void)token; out.live_bytes += loan.bytes; ++out.live_blocks; }
}
Result pool_acquire(uint64_t bytes, uint64_t alignment, void** out, uint64_t* token) noexcept {
    *out = nullptr; *token = 0;
    void* pointer = nullptr;
    if (posix_memalign(&pointer, alignment, bytes)) return {Stage::pool_limit, -1};
    *token = ++fixture::serial; *out = pointer;
    fixture::live.emplace(*token, fixture::Loan{pointer, bytes}); return {};
}
Result pool_release(uint64_t token) noexcept {
    if (fixture::hold_releases) return {Stage::unmap, -2};
    if (fixture::fail_once) { fixture::fail_once = false; return {Stage::unmap, -1}; }
    const auto found = fixture::live.find(token);
    if (found == fixture::live.end()) return {Stage::pool_not_owned, -1};
    free(found->second.pointer); fixture::live.erase(found); return {};
}
}
int main() {
    using namespace fixture;
    char directory[] = "/tmp/neoswap-retirement-proof-XXXXXX"; assert(mkdtemp(directory));
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 64 * MiB, 0, MiB, 1, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    NeoSwap_SetCPUBufferExperiment(1); NeoSwap_SetCPUBufferPressure(0);
    const auto* api = NeoSwap_GetAPI(NEOSWAP_ABI);
    for (unsigned scenario = 0; scenario < 3; ++scenario) {
        const unsigned count = scenario == 0 ? 40 : 1;
        NeoSwapFastStats before{}; assert(NeoSwap_FastSnapshot(&before) == NEOSWAP_OK);
        std::vector<void*> queued;
        for (unsigned n = 0; n < count; ++n) {
            void* loan = nullptr;
            assert(api->allocate(0, NEOSWAP_CPU_CACHE | NEOSWAP_REQUEST_FAST, 64 * KiB, 65536, &loan) == NEOSWAP_OK);
            assert(loan); queued.push_back(loan);
        }
        for (void* loan : queued) assert(api->release(loan) == NEOSWAP_OK);
        assert(NeoSwap_LiveBytes(NEOSWAP_RPCS3) == count * 64 * KiB && live.size() == count);
        fail_once = scenario == 1; hold_releases = scenario == 2;
        const auto proof = neostation::donation::prove_fast_retirement(count, count * 64 * KiB, before);
        assert(proof.queued_loans == count && proof.queued_bytes == count * 64 * KiB);
        assert(proof.maximum_passes == (count + 31) / 32 + 4);
        if (scenario != 2) {
            assert(proof.passed && proof.completed_loans == count && !proof.pending_loans);
            assert(proof.passes == 2 && proof.failures == (scenario == 1 ? 1 : 0));
            assert(!proof.host_live_bytes && !proof.pool_live_bytes && !proof.pool_live_blocks);
            assert(!NeoSwap_LiveBytes(NEOSWAP_RPCS3) && live.empty());
        } else {
            assert(!proof.passed && proof.passes == proof.maximum_passes);
            assert(proof.pending_loans == 1 && !proof.completed_loans);
            assert(proof.host_live_bytes == 64 * KiB && proof.pool_live_blocks == 1 && live.size() == 1);
            hold_releases = false;
            (void)NeoSwap_RelayLoanMaintain(0, 1);
            assert(!NeoSwap_LiveBytes(NEOSWAP_RPCS3) && live.empty());
        }
    }
    NeoSwapStats stats{}; stats.struct_size = sizeof(stats);
    assert(NeoSwap_Snapshot(&stats) == NEOSWAP_OK && !stats.live_blocks && !stats.allocated_disk_bytes);
    config.capacity_bytes = 0; assert(NeoSwap_Configure(nullptr, &config) == NEOSWAP_OK);
    assert(rmdir(directory) == 0);
    puts("PASS production FAST retirement proof: 40 loans/two maintenance passes, transient cleanup retry, permanent failure hits bound and retains ownership, zero remaining host/pool loans, no disk");
}
