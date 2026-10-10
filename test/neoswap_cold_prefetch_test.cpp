// Executes the cold-storage prefetch planner and the POSIX read-advice
// helpers over a real temporary file. Pure planning evidence: it proves the
// order and bounds of the plan, the pressure cancellation and that advice
// calls succeed on a real descriptor. It is NOT iPhone storage latency or
// gameplay evidence.
#include "NeoSwapColdPrefetch.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>
#include <unistd.h>

using namespace neostation::prefetch;

namespace {
bool has(const Plan& plan, std::uint64_t object, std::uint32_t chunk, Priority priority) {
    for (std::size_t i = 0; i < plan.count; ++i)
        if (plan.entries[i].object == object && plan.entries[i].chunk == chunk && plan.entries[i].priority == priority)
            return true;
    return false;
}
std::size_t position(const Plan& plan, std::uint64_t object, std::uint32_t chunk) {
    for (std::size_t i = 0; i < plan.count; ++i)
        if (plan.entries[i].object == object && plan.entries[i].chunk == chunk) return i;
    return plan.count;
}
}

int main() {
    Planner planner;
    // One access is not a run: nothing is predicted beyond recency.
    planner.observe(7, 0, 64, 1000);
    Plan plan = planner.plan(1000, false);
    assert(plan.count == 0); // the consumer holds chunk 0; no run yet
    // A second ascending access makes a run: the next four chunks are planned.
    planner.observe(7, 1, 64, 1010);
    plan = planner.plan(1010, false);
    assert(plan.count == 5);
    for (std::uint32_t ahead = 1; ahead <= run_lookahead; ++ahead) assert(has(plan, 7, 1 + ahead, Priority::sequential));
    assert(has(plan, 7, 0, Priority::recent)); // the previous chunk stays warm
    assert(position(plan, 7, 2) < position(plan, 7, 0)); // look-ahead precedes recency
    // The run stops at the end of the object.
    Planner tail;
    tail.observe(9, 62, 64, 2000);
    tail.observe(9, 63, 64, 2010);
    plan = tail.plan(2010, false);
    assert(plan.count == 1 && has(plan, 9, 62, Priority::recent));
    // A non-ascending access breaks the run.
    planner.observe(7, 40, 64, 1020);
    plan = planner.plan(1020, false);
    assert(!has(plan, 7, 41, Priority::sequential) && has(plan, 7, 1, Priority::recent) && has(plan, 7, 0, Priority::recent));
    // Demanded chunks lead every plan and are consumed by that plan.
    planner.observe(7, 41, 64, 1030, true);
    plan = planner.plan(1030, false);
    assert(plan.count >= 1 && plan.entries[0].object == 7 && plan.entries[0].chunk == 41 &&
           plan.entries[0].priority == Priority::demanded);
    assert(has(plan, 7, 42, Priority::sequential)); // 40 -> 41 restarted a run
    plan = planner.plan(1031, false);
    assert(!has(plan, 7, 41, Priority::demanded));
    // Pressure keeps the demanded entry only and counts every dropped speculation.
    planner.observe(7, 42, 64, 1040, true);
    plan = planner.plan(1040, true);
    assert(plan.count == 1 && plan.entries[0].priority == Priority::demanded);
    assert(plan.cancelled_speculative > 0 && planner.stats().cancelled_speculative == plan.cancelled_speculative);
    // Recency expires after the window.
    plan = planner.plan(1040 + recency_window_ms + 1, false);
    for (std::size_t i = 0; i < plan.count; ++i) assert(plan.entries[i].priority == Priority::sequential);
    // Plans are bounded and the most recently active object comes first.
    Planner many;
    for (std::uint64_t object = 1; object <= 8; ++object) {
        many.observe(object, 0, 100, 5000 + object);
        many.observe(object, 1, 100, 5100 + object);
    }
    plan = many.plan(5200, false, 6);
    assert(plan.count == 6);
    assert(plan.entries[0].object == 8 && plan.entries[0].chunk == 2 && plan.entries[0].priority == Priority::sequential);
    plan = many.plan(5200, false);
    assert(plan.count == maximum_plan_entries);
    // Tracking is bounded: the least recently used object is evicted.
    Planner bounded;
    for (std::uint64_t object = 0; object < maximum_tracked_objects + 3; ++object) bounded.observe(object, 0, 4, 100 + object);
    assert(bounded.tracked() == maximum_tracked_objects && bounded.stats().evicted_objects == 3);
    bounded.forget(5);
    assert(bounded.tracked() == maximum_tracked_objects - 1);
    bounded.reset();
    assert(bounded.tracked() == 0);
    // Recreating an object with another chunk count forgets its run.
    Planner resized;
    resized.observe(3, 10, 32, 1);
    resized.observe(3, 11, 32, 2);
    assert(resized.plan(2, false).count > 0);
    resized.observe(3, 12, 64, 3);
    assert(resized.plan(3, false).count == 0);
    // Read advice and pre-faulting on a real file.
    char name[] = "/tmp/neoswap-cold-prefetch-XXXXXX";
    const int fd = ::mkstemp(name);
    assert(fd >= 0 && ::unlink(name) == 0);
    const std::size_t page = static_cast<std::size_t>(::sysconf(_SC_PAGESIZE));
    std::vector<unsigned char> content(page * 8, 0x5a);
    assert(::pwrite(fd, content.data(), content.size(), 0) == static_cast<ssize_t>(content.size()));
    assert(advise_read(fd, 0, page * 4) == 0);
    assert(advise_read(fd, page * 4, page * 4) == 0);
    assert(advise_read(-1, 0, page) == EINVAL && advise_read(fd, 0, 0) == EINVAL);
    assert(set_readahead(fd, true) == 0 && set_readahead(fd, false) == 0 && set_readahead(-1, true) == EINVAL);
    void* window = ::mmap(nullptr, content.size(), PROT_READ, MAP_PRIVATE, fd, 0);
    assert(window != MAP_FAILED);
    assert(prefault(window, content.size(), page) == 8);
    assert(prefault(window, 1, page) == 1 && prefault(nullptr, page, page) == 0 && prefault(window, 0, page) == 0);
    assert(static_cast<const unsigned char*>(window)[page * 7] == 0x5a);
    assert(::munmap(window, content.size()) == 0 && ::close(fd) == 0);
    const Stats stats = planner.stats();
    assert(stats.observations == 5 && stats.demanded == 2 && stats.plans >= 6);
    std::printf("PASS cold prefetch: sequential look-ahead, recency window, demanded-first, pressure cancellation, "
                "bounded plan and tracking, read advice and pre-fault on a real file\n");
    return 0;
}
