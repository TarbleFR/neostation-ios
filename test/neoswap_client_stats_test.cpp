#include "NeoSwapClient.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <unistd.h>
#include <sys/wait.h>

static NeoSwapClientStats snapshot() {
    NeoSwapClientStats stats{};
    stats.struct_size = sizeof(stats);
    stats.abi_version = NEOSWAP_CLIENT_STATS_ABI;
    assert(neostation::swap::snapshot(&stats) == NEOSWAP_OK);
    return stats;
}

// A v1 host predating FAST only recognizes the original kinds. It must see
// one flagged request and refuse it; the client may never retry a slow kind.
static int old_host_calls = 0;
static int old_allocate(uint32_t, uint32_t kind, uint64_t, uint64_t, void** out) {
    ++old_host_calls;
    assert(kind & NEOSWAP_REQUEST_FAST);
    *out = nullptr;
    return NEOSWAP_INVALID;
}
int main() {
    const pid_t child = fork(); assert(child >= 0);
    if (!child) {
        const NeoSwapAPI old_api{sizeof(NeoSwapAPI), NEOSWAP_ABI, old_allocate,
            [](void*) { return int{NEOSWAP_NOT_OWNED}; }, [](void*) { return int{NEOSWAP_NOT_OWNED}; },
            [](uint32_t) { return 1; }};
        assert(neostation::swap::install(&old_api) == NEOSWAP_OK);
        assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 1024 * 1024, 65536));
        assert(!neostation::swap::try_allocate_cpu(NEOSWAP_RPCS3, 64 * 1024, 64));
        assert(old_host_calls == 2 && snapshot().last_result == NEOSWAP_INVALID);
        _exit(0);
    }
    int status = 0; assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);

    static_assert(sizeof(NeoSwapClientStats) == 64);
    constexpr size_t MiB = 1024 * 1024;
    char directory[] = "/tmp/neoswap-client-stats-XXXXXX";
    assert(mkdtemp(directory));
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 1024, 16));
    assert(snapshot().skipped_small == 1 && !snapshot().eligible_attempts);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16));
    assert(snapshot().missing_api == 1 && !snapshot().eligible_attempts);
    const NeoSwapAPI* api = NeoSwap_GetAPI(NEOSWAP_ABI);
    assert(neostation::swap::install(api) == NEOSWAP_OK);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16));
    assert(snapshot().disabled == 1 && !snapshot().eligible_attempts);
    NeoSwapConfig config{sizeof(config), NEOSWAP_ABI, 8*MiB, 0, MiB, 1u, 0};
    assert(NeoSwap_Configure(directory, &config) == NEOSWAP_OK);
    void* address = neostation::swap::try_allocate(NEOSWAP_RPCS3, MiB, 16);
    // FAST requests never create a backing file on the caller's thread.
    assert(!address && snapshot().eligible_attempts == 1);
    assert(!snapshot().successful_allocations && snapshot().failed_allocations == 1);
    assert(snapshot().last_result == NEOSWAP_BUSY);
    assert(!neostation::swap::try_allocate(NEOSWAP_RPCS3, 8*MiB, 16));
    assert(snapshot().failed_allocations == 2 && snapshot().eligible_attempts == 2);
    assert(snapshot().last_result == NEOSWAP_BUSY);
    assert(neostation::swap::release(address) == NEOSWAP_NOT_OWNED);
    NeoSwapClientStats invalid{};
    invalid.struct_size = sizeof(invalid);
    invalid.abi_version = 99;
    assert(neostation::swap::snapshot(&invalid) == NEOSWAP_INVALID);
    assert(invalid.abi_version == 99 && !invalid.skipped_small);
    assert(neostation::swap::snapshot(nullptr) == NEOSWAP_INVALID);
    invalid.abi_version = NEOSWAP_CLIENT_STATS_ABI;
    invalid.struct_size -= 1;
    assert(neostation::swap::snapshot(&invalid) == NEOSWAP_INVALID);
    config.capacity_bytes = 0;
    assert(NeoSwap_Configure(nullptr, &config) == NEOSWAP_OK);
    assert(rmdir(directory) == 0);
    puts("PASS: client telemetry distinguishes small, unbound, disabled, safe fast misses without disk IO, older v1 host refuses without slow retry; ABI unchanged");
}
