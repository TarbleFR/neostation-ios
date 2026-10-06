// Executes the exact NeoSwap global budget decision table. Pure policy: no
// kernel sample, allocation or I/O. This is not iPhone residency evidence.
#include "NeoSwapBudget.h"
#include <cassert>
#include <cstdio>
#include <cstring>

using namespace neostation::budget;

namespace {
Inputs device_inputs() {
    Inputs in{};
    in.session_active = true;
    in.physical_bytes = 7989460992ULL; // iPhone 16 Pro Max reported physical memory
    in.host_footprint_bytes = 3ULL * GiB;
    in.host_footprint_valid = true;
    in.host_available_bytes = 3900 * MiB;
    in.host_available_valid = true;
    in.system_usable_bytes = 2 * GiB;
    in.system_valid = true;
    in.system_pressure = Pressure::normal;
    in.relay_ready = true;
    in.relay_capacity_bytes = 8 * GiB;
    in.relay_guest_live_bytes = 1020788736ULL;
    in.relay_host_live_bytes = 160 * MiB;
    in.donors_available = true;
    in.donor_prepared_bytes = 512 * MiB;
    in.donor_live_bytes = 48 * MiB;
    in.file_live_bytes = 32 * MiB;
    in.storage_archived_live_bytes = 20 * MiB;
    return in;
}
}

int main() {
    static_assert(operational_reserve(0, false) == reserve_floor_bytes);
    static_assert(operational_reserve(4 * GiB, false) == reserve_floor_bytes);
    static_assert(operational_reserve(8 * GiB, false) == 512 * MiB);
    static_assert(operational_reserve(64 * GiB, false) == reserve_ceiling_bytes);
    static_assert(operational_reserve(8 * GiB, true) == 1024 * MiB);
    static_assert(saturating_add(UINT64_MAX, 1) == UINT64_MAX);
    static_assert(clamp(5, 10, 20) == 10 && clamp(25, 10, 20) == 20 && clamp(15, 10, 20) == 15);
    assert(std::strcmp(state_name(State::growing), "growing") == 0 && std::strcmp(state_name(State::pressure), "pressure") == 0);

    // Idle: no session means no growth and retired donors, but sums stay honest.
    Inputs idle = device_inputs();
    idle.session_active = false;
    Decision d = decide(idle, {});
    assert(d.state == State::idle && !d.host_loans_admitted && !d.small_cpu_admitted);
    assert(d.host_loan_quota_bytes == 0 && d.donor_floor_bytes == 0 && !d.donor_growth_admitted);
    assert(d.mobilized_bytes == idle.relay_guest_live_bytes + idle.relay_host_live_bytes + idle.donor_live_bytes);
    assert(d.neoswap_total_bytes == d.mobilized_bytes + idle.file_live_bytes + idle.storage_archived_live_bytes);
    assert(d.guest_reserve_bytes == guest_reserve_floor_bytes);

    // Growing: measured room above the reserve admits host loans bounded by room.
    Inputs grow = device_inputs();
    d = decide(grow, {});
    const auto reserve = operational_reserve(grow.physical_bytes, false);
    assert(reserve == clamp(grow.physical_bytes / 16, reserve_floor_bytes, reserve_ceiling_bytes));
    assert(d.state == State::growing && d.host_loans_admitted && d.small_cpu_admitted);
    assert(d.growth_room_bytes == grow.system_usable_bytes - reserve);
    assert(d.host_loan_quota_bytes == grow.relay_host_live_bytes + d.growth_room_bytes);
    assert(d.donor_floor_bytes == 0 && d.donor_reserve_bytes == relay_donor_reserve_bytes);
    assert(d.donor_growth_admitted && !d.storage_shrink_requested);
    assert(std::strcmp(d.reason, "measured_room_available") == 0);

    // The quota never exceeds the relay capacity left after the guest reserve.
    Inputs huge = device_inputs();
    huge.system_usable_bytes = 64 * GiB;
    d = decide(huge, {});
    assert(d.host_loan_quota_bytes == huge.relay_capacity_bytes - guest_reserve_floor_bytes);
    huge.relay_guest_live_bytes = 2 * GiB; // guest already above the floor: reserve follows it
    d = decide(huge, {});
    assert(d.guest_reserve_bytes == 2 * GiB && d.host_loan_quota_bytes == 6 * GiB);
    huge.relay_host_live_bytes = 6 * GiB; // capacity exhausted: hold, never below live
    d = decide(huge, {});
    assert(d.state == State::holding && !d.host_loans_admitted && d.host_loan_quota_bytes == 6 * GiB);
    assert(std::strcmp(d.reason, "relay_host_capacity_exhausted") == 0);
    assert(d.donor_floor_bytes == legacy_donor_floor_bytes); // donors become the fallback again

    // Holding: room below one growth quantum keeps live loans and refuses new ones.
    Inputs tight = device_inputs();
    tight.system_usable_bytes = reserve + 32 * MiB;
    d = decide(tight, {});
    assert(d.state == State::holding && !d.host_loans_admitted && !d.donor_growth_admitted);
    assert(d.host_loan_quota_bytes == tight.relay_host_live_bytes + 32 * MiB);
    assert(std::strcmp(d.reason, "room_below_growth_quantum") == 0);
    assert(d.small_cpu_admitted); // donors are available and room stays above 128 MiB

    // Shrinking: below the reserve the storage tier archives; hysteresis holds
    // until the room recovers to 1.5x the reserve.
    Inputs low = device_inputs();
    low.system_usable_bytes = reserve - MiB;
    d = decide(low, {});
    assert(d.state == State::shrinking && d.storage_shrink_requested && !d.small_cpu_admitted);
    assert(d.host_loan_quota_bytes == low.relay_host_live_bytes && !d.host_loans_admitted);
    Inputs partial = device_inputs();
    partial.system_usable_bytes = reserve + reserve / 4;
    Decision after = decide(partial, d);
    assert(after.state == State::shrinking && std::strcmp(after.reason, "shrink_hysteresis") == 0);
    partial.system_usable_bytes = reserve + reserve / 2;
    after = decide(partial, after);
    assert(after.state == State::holding || after.state == State::growing);
    assert(!after.storage_shrink_requested);

    // Pressure: dispatch or kernel warning fails closed, retains live loans and
    // doubles the reserve for the next decision.
    Inputs warned = device_inputs();
    warned.dispatch_warning = true;
    d = decide(warned, {});
    assert(d.state == State::pressure && !d.host_loans_admitted && !d.small_cpu_admitted);
    assert(d.host_loan_quota_bytes == warned.relay_host_live_bytes && d.storage_shrink_requested);
    assert(d.operational_reserve_bytes == 2 * reserve && !d.donor_growth_admitted);
    assert(std::strcmp(d.reason, "dispatch_memory_pressure") == 0);
    warned.dispatch_warning = false;
    warned.system_pressure = Pressure::critical;
    d = decide(warned, {});
    assert(d.state == State::pressure && std::strcmp(d.reason, "kernel_memory_pressure") == 0);
    // Leaving pressure still obeys the shrink hysteresis before growth resumes.
    Inputs relieved = device_inputs();
    relieved.system_usable_bytes = reserve + reserve / 4;
    after = decide(relieved, d);
    assert(after.state == State::shrinking);
    relieved.system_usable_bytes = 2 * GiB;
    after = decide(relieved, after);
    assert(after.state == State::growing);

    // Unknown system headroom holds everything: a missing measurement is not room.
    Inputs unknown = device_inputs();
    unknown.system_valid = false;
    d = decide(unknown, {});
    assert(d.state == State::holding && !d.host_loans_admitted && !d.small_cpu_admitted);
    assert(d.growth_room_bytes == 0 && d.host_loan_quota_bytes == unknown.relay_host_live_bytes);
    assert(std::strcmp(d.reason, "system_headroom_unknown") == 0);

    // Warming: without the relay, donors keep their legacy floor and reserve.
    Inputs warm = device_inputs();
    warm.relay_ready = false;
    d = decide(warm, {});
    assert(d.state == State::warming && !d.host_loans_admitted && d.host_loan_quota_bytes == 0);
    assert(d.donor_floor_bytes == legacy_donor_floor_bytes && d.donor_reserve_bytes == legacy_donor_reserve_bytes);
    assert(d.donor_growth_admitted && d.small_cpu_admitted);
    warm.donors_available = false;
    d = decide(warm, {});
    assert(!d.small_cpu_admitted && std::strcmp(d.reason, "relay_not_ready") == 0);

    // Small CPU buffers need 128 MiB of measured system room even with donors.
    Inputs scarce = device_inputs();
    scarce.system_usable_bytes = 100 * MiB;
    d = decide(scarce, {});
    assert(d.state == State::shrinking && !d.small_cpu_admitted);

    // Thermal pressure only raises the reserve; it does not fail closed alone.
    Inputs hot = device_inputs();
    hot.thermal_serious = true;
    d = decide(hot, {});
    assert(d.operational_reserve_bytes == 2 * reserve && d.state == State::growing);

    // Saturating sums never wrap for impossible inputs.
    Inputs wrap = device_inputs();
    wrap.relay_guest_live_bytes = UINT64_MAX;
    d = decide(wrap, {});
    assert(d.mobilized_bytes == UINT64_MAX && d.neoswap_total_bytes == UINT64_MAX);

    std::puts("PASS NeoSwap budget: idle/warming/growing/holding/shrinking/pressure, measured room, guest reserve, "
              "relay host quota bounds, donor floors, small-CPU gate, hysteresis, saturating sums");
}
