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
    assert(d.host_loan_quota_bytes == grow.relay_host_live_bytes + maximum_growth_grant_bytes);
    assert(d.donor_floor_bytes == 0 && d.donor_reserve_bytes == relay_donor_reserve_bytes);
    // The relay ceiling took the bounded grant: nothing is left for donors
    // in the same sample, so the room is never granted twice.
    assert(d.host_loan_quota_bytes - grow.relay_host_live_bytes == maximum_growth_grant_bytes);
    assert(d.donor_room_bytes == 0 && !d.donor_growth_admitted && !d.storage_shrink_requested);
    assert(std::strcmp(d.reason, "measured_room_available") == 0);

    // When the relay capacity caps the ceiling, donors receive the remainder of
    // the grant: relay growth plus donor room equals the bounded grant exactly.
    Inputs capped = device_inputs();
    capped.relay_capacity_bytes = guest_reserve_floor_bytes + capped.relay_host_live_bytes + 10 * MiB;
    d = decide(capped, {});
    assert(d.state == State::growing && d.host_loans_admitted);
    assert(d.host_loan_quota_bytes == capped.relay_host_live_bytes + 10 * MiB);
    assert(d.donor_room_bytes == maximum_growth_grant_bytes - 10 * MiB && d.donor_growth_admitted);
    assert((d.host_loan_quota_bytes - capped.relay_host_live_bytes) + d.donor_room_bytes == maximum_growth_grant_bytes);

    // The process jetsam headroom cannot throttle relay or donor pages, but
    // below the reserve it asks the storage tier to archive cold data early.
    // A missing process sample changes nothing: the system sample decides.
    Inputs jetsam = device_inputs();
    jetsam.host_available_bytes = reserve - MiB;
    d = decide(jetsam, {});
    assert(d.state == State::growing && d.host_loans_admitted && d.storage_shrink_requested);
    jetsam.host_available_bytes = 0;
    assert(decide(jetsam, {}).storage_shrink_requested); // exhausted is a valid sample
    jetsam.host_available_valid = false;
    d = decide(jetsam, {});
    assert(d.state == State::growing && !d.storage_shrink_requested);

    // The quota never exceeds the relay capacity left after the guest reserve.
    Inputs huge = device_inputs();
    huge.system_usable_bytes = 64 * GiB;
    d = decide(huge, {});
    assert(d.host_loan_quota_bytes == huge.relay_host_live_bytes + maximum_growth_grant_bytes);
    huge.relay_guest_live_bytes = 2 * GiB; // guest already above the floor: reserve follows it
    d = decide(huge, {});
    assert(d.guest_reserve_bytes == 2 * GiB && d.host_loan_quota_bytes == huge.relay_host_live_bytes + maximum_growth_grant_bytes);
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

    // Hysteresis between growing and holding: admission enters with one growth
    // quantum of room and leaves only below half of it, so sample jitter or the
    // bytes a maintenance pass hands back cannot flip the state every tick.
    Inputs edge = device_inputs();
    edge.system_usable_bytes = reserve + growth_quantum_bytes - MiB; // 63 MiB of room
    Decision held = decide(edge, {});
    assert(held.state == State::holding && !held.host_loans_admitted && !held.donor_growth_admitted);
    assert(std::strcmp(held.reason, "room_below_growth_quantum") == 0);
    Decision growing = decide(device_inputs(), {});
    assert(growing.state == State::growing);
    Decision stays = decide(edge, growing);
    assert(stays.state == State::growing && stays.host_loans_admitted);
    assert(stays.donor_room_bytes == 0 && !stays.donor_growth_admitted); // the relay ceiling took the room
    edge.system_usable_bytes = reserve + growth_hold_quantum_bytes + MiB; // 33 MiB: still growing
    stays = decide(edge, stays);
    assert(stays.state == State::growing && stays.host_loans_admitted);
    edge.system_usable_bytes = reserve + growth_hold_quantum_bytes - MiB; // 31 MiB: leaves
    held = decide(edge, stays);
    assert(held.state == State::holding && !held.host_loans_admitted && !held.donor_growth_admitted);
    edge.system_usable_bytes = reserve + growth_quantum_bytes - MiB; // 63 MiB from holding: not enough
    held = decide(edge, held);
    assert(held.state == State::holding);
    edge.system_usable_bytes = reserve + growth_quantum_bytes; // one full quantum re-admits
    assert(decide(edge, held).state == State::growing);
    static_assert(growth_hold_quantum_bytes * 2 == growth_quantum_bytes);

    // Even a wildly optimistic system sample cannot admit GiB bursts. Relay
    // and donor allowances share one 256 MiB grant; live loans stay valid.
    for (unsigned i = 0; i < 100; ++i) {
        Inputs burst = device_inputs();
        burst.system_usable_bytes = (1ULL + i) * GiB;
        burst.relay_capacity_bytes = 64 * GiB;
        const auto bounded = decide(burst, {});
        const auto hostGrowth = bounded.host_loan_quota_bytes - burst.relay_host_live_bytes;
        assert(hostGrowth + bounded.donor_room_bytes <= maximum_growth_grant_bytes);
        burst.relay_ready = false;
        assert(decide(burst, {}).donor_room_bytes <= maximum_growth_grant_bytes);
    }

    // Saturating sums never wrap for impossible inputs.
    Inputs wrap = device_inputs();
    wrap.relay_guest_live_bytes = UINT64_MAX;
    d = decide(wrap, {});
    assert(d.mobilized_bytes == UINT64_MAX && d.neoswap_total_bytes == UINT64_MAX);

    // Build434: measured jetsam envelope of the host process.
    static_assert(host_safety_reserve(0) == host_reserve_floor_bytes);
    static_assert(host_safety_reserve(6 * GiB) == 384 * MiB);
    static_assert(host_safety_reserve(8 * GiB) == 512 * MiB);
    static_assert(host_safety_reserve(64 * GiB) == host_reserve_ceiling_bytes);
    static_assert(ramped(256 * MiB, 100) == 256 * MiB && ramped(256 * MiB, 50) == 128 * MiB);
    static_assert(ramped(256 * MiB, 25) == 64 * MiB && ramped(0, 25) == 0 && ramped(99, 50) == 49);
    static_assert(growth_ramp(3 * GiB, 384 * MiB, true) == growth_ramp_full_percent);
    static_assert(growth_ramp(500 * MiB, 384 * MiB, true) == growth_ramp_half_percent);
    static_assert(growth_ramp(100 * MiB, 384 * MiB, true) == growth_ramp_quarter_percent);
    static_assert(growth_ramp(3 * GiB, 384 * MiB, false) == 0);
    {
        // The limit is footprint plus headroom of the same tick, bounded by the RAM.
        Inputs sampled = device_inputs(); // 3 GiB footprint, 3900 MiB headroom, 7.44 GiB RAM
        const auto expected_limit = 3 * GiB + 3900 * MiB;
        assert(host_limit_sample(sampled) == expected_limit);
        Decision envelope = decide(sampled, {});
        assert(envelope.host_limit_valid && envelope.host_limit_estimate_bytes == expected_limit);
        assert(envelope.host_safety_reserve_bytes == host_safety_reserve(expected_limit));
        assert(envelope.host_allocatable_bytes == expected_limit - envelope.host_safety_reserve_bytes);
        assert(envelope.host_room_valid && envelope.host_room_bytes == envelope.host_allocatable_bytes - 3 * GiB);
        assert(envelope.growth_ramp_percent == growth_ramp_full_percent && envelope.state == State::growing);
        assert(!envelope.storage_shrink_requested);
        // An over-reported sum cannot exceed the physical memory.
        Inputs absurd = sampled;
        absurd.host_available_bytes = 64 * GiB;
        assert(host_limit_sample(absurd) == absurd.physical_bytes);
        // Either reading missing: no sample, and the previous estimate carries over.
        Inputs blind = sampled;
        blind.host_available_valid = false;
        assert(host_limit_sample(blind) == 0);
        Decision carried = decide(blind, envelope);
        assert(carried.host_limit_valid && carried.host_limit_estimate_bytes == expected_limit);
        assert(carried.host_room_valid); // the footprint is still known
        blind.host_footprint_valid = false;
        carried = decide(blind, envelope);
        assert(carried.host_limit_valid && !carried.host_room_valid);
        assert(carried.growth_ramp_percent == growth_ramp_full_percent); // unknown room is not a brake
        // Session high-water mark: a lower later sample never lowers the estimate,
        // a higher one raises it, and a fresh session (no previous) restarts it.
        Inputs lower = sampled;
        lower.host_available_bytes = 1 * GiB;
        Decision kept = decide(lower, envelope);
        assert(kept.host_limit_estimate_bytes == expected_limit);
        Inputs higher = sampled;
        higher.host_available_bytes = 4000 * MiB;
        assert(decide(higher, envelope).host_limit_estimate_bytes == 3 * GiB + 4000 * MiB);
        assert(decide(lower, {}).host_limit_estimate_bytes == 3 * GiB + 1 * GiB);
        // The envelope brakes the shared grant as the host approaches its
        // allocatable share: half below two reserves, a quarter below one, and
        // the room at zero asks the storage tier to archive before the
        // operational reserve of os_proc_available_memory() is reached.
        const auto reserve_h = envelope.host_safety_reserve_bytes;
        Inputs near = sampled;
        const auto occupy = [&](std::uint64_t footprint) {
            near.host_footprint_bytes = footprint;
            near.host_available_bytes = expected_limit - footprint; // same limit, less headroom
        };
        occupy(expected_limit - reserve_h - reserve_h - reserve_h / 2); // 1.5 reserves of room
        Decision braked = decide(near, envelope);
        assert(braked.state == State::growing && braked.growth_ramp_percent == growth_ramp_half_percent);
        assert(braked.host_loan_quota_bytes == near.relay_host_live_bytes + maximum_growth_grant_bytes / 2);
        assert(!braked.storage_shrink_requested);
        occupy(expected_limit - reserve_h - reserve_h / 2); // half a reserve of room
        braked = decide(near, envelope);
        assert(braked.growth_ramp_percent == growth_ramp_quarter_percent);
        assert(braked.host_loan_quota_bytes == near.relay_host_live_bytes + maximum_growth_grant_bytes / 4);
        assert(braked.host_loans_admitted); // a brake, never a second gate
        occupy(expected_limit - reserve_h); // room exhausted
        braked = decide(near, envelope);
        assert(braked.host_room_valid && braked.host_room_bytes == 0 && braked.storage_shrink_requested);
        assert(braked.state == State::growing); // the system sample still admits, slowly
        // Relay growth and donor room still share exactly the ramped grant.
        Inputs capped_near = near;
        capped_near.relay_capacity_bytes = guest_reserve_floor_bytes + capped_near.relay_host_live_bytes + 10 * MiB;
        braked = decide(capped_near, envelope);
        assert((braked.host_loan_quota_bytes - capped_near.relay_host_live_bytes) + braked.donor_room_bytes
               == maximum_growth_grant_bytes / 4);
        // Background: the inactive limit is far lower than the measured one, so
        // the application state fails closed like pressure, keeps live loans,
        // archives cold data and opens no growth at all.
        Inputs background = sampled;
        background.foreground = false;
        Decision parked = decide(background, envelope);
        assert(parked.state == State::pressure && std::strcmp(parked.reason, "application_background") == 0);
        assert(!parked.host_loans_admitted && !parked.donor_growth_admitted && !parked.small_cpu_admitted);
        assert(parked.host_loan_quota_bytes == background.relay_host_live_bytes && parked.storage_shrink_requested);
        assert(parked.growth_ramp_percent == 0 && parked.host_limit_estimate_bytes == expected_limit);
        // Returning to the foreground obeys the shrink hysteresis, like pressure.
        Decision resumed = decide(sampled, parked);
        assert(resumed.state == State::shrinking || resumed.state == State::growing);
        Inputs ample = sampled;
        ample.system_usable_bytes = 4 * GiB;
        assert(decide(ample, resumed).state == State::growing);
        // Pressure and background keep the envelope estimate for display.
        Inputs warned_bg = sampled;
        warned_bg.dispatch_warning = true;
        assert(decide(warned_bg, envelope).host_limit_estimate_bytes == expected_limit);
        assert(decide(warned_bg, envelope).growth_ramp_percent == 0);
    }

    std::puts("PASS NeoSwap budget: idle/warming/growing/holding/shrinking/pressure, measured room, guest reserve, "
              "relay host quota bounds, donor floors, small-CPU gate, hysteresis, saturating sums, "
              "measured host envelope (limit estimate, safety reserve, ramp, background)");
}
