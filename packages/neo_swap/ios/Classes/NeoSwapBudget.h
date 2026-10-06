// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <cstdint>

// NeoSwap global memory budget: one measured-resource policy that decides how
// much memory outside the host process footprint RPCS3 may hold, which backing
// serves it (guest relay, host relay loans, donors, files, storage), and when
// the storage tier should start archiving cold data.
//
// This header is pure policy. It performs no kernel call, allocation or I/O,
// so the exact decision table is executed by portable sanitized tests. The
// plugin samples the inputs on its serial diagnostics timer and applies the
// decision to the broker, the relay service, the donor manager and storage.
//
// Units: every *_bytes field is a byte count. Capacities are retained
// VM-object capacity, never resident physical RAM. "Mobilized" bytes are live
// backing intervals charged outside the host footprint (relay objects whose
// creator exited, donor-owned purgeable objects), not pages proven resident.
namespace neostation::budget {
constexpr std::uint64_t MiB = 1024ULL * 1024;
constexpr std::uint64_t GiB = 1024ULL * MiB;

enum class Pressure : std::uint32_t { unobserved = 0, normal = 1, warning = 2, critical = 3 };
enum class State : std::uint32_t {
    idle = 0,      // no RPCS3 session: nothing grows, idle reserves retire
    warming = 1,   // session active, relay not ready: donors provide the floor
    growing = 2,   // measured room available: new host loans and donor growth
    holding = 3,   // little room: live loans retained, no new backing
    shrinking = 4, // below the operational reserve: storage tier archives cold data
    pressure = 5,  // kernel/dispatch pressure: fail closed, retain live loans
};

struct Inputs {
    bool session_active = false;
    std::uint64_t physical_bytes = 0;
    // TASK_VM_INFO.phys_footprint of the host and os_proc_available_memory().
    std::uint64_t host_footprint_bytes = 0;
    bool host_footprint_valid = false;
    std::uint64_t host_available_bytes = 0;
    bool host_available_valid = false;
    // donation::system_headroom(): kernel free/purgeable sample minus margin,
    // or the memorystatus estimate. Not a process limit.
    std::uint64_t system_usable_bytes = 0;
    bool system_valid = false;
    Pressure system_pressure = Pressure::unobserved;
    bool dispatch_warning = false;
    bool thermal_serious = false;
    // Guest page relay: retained named-object capacity and live backing.
    bool relay_ready = false;
    std::uint64_t relay_capacity_bytes = 0;
    std::uint64_t relay_guest_live_bytes = 0;
    std::uint64_t relay_host_live_bytes = 0;
    // Donor pool: verified prepared bytes and active loans.
    bool donors_available = false;
    std::uint64_t donor_prepared_bytes = 0;
    std::uint64_t donor_live_bytes = 0;
    // File fallback and storage tier (live archived bytes, not cumulative).
    std::uint64_t file_live_bytes = 0;
    std::uint64_t storage_archived_live_bytes = 0;
};

struct Decision {
    State state = State::idle;
    std::uint64_t operational_reserve_bytes = 0;
    std::uint64_t growth_room_bytes = 0;
    std::uint64_t guest_reserve_bytes = 0;
    // Relay host loans: ceiling of live bytes the broker may hold for RSX CPU
    // data, host-visible Vulkan buffers and video frames. Existing loans are
    // never revoked; a ceiling below the live value only refuses new loans.
    std::uint64_t host_loan_quota_bytes = 0;
    bool host_loans_admitted = false;
    bool small_cpu_admitted = false;
    // Donor manager policy: floor and reserve for adaptive_donation_target().
    std::uint64_t donor_floor_bytes = 0;
    std::uint64_t donor_reserve_bytes = 0;
    bool donor_growth_admitted = false;
    // Storage tier: prefer archiving cold owned data while this is set.
    bool storage_shrink_requested = false;
    std::uint64_t mobilized_bytes = 0;      // relay guest + relay host + donor live
    std::uint64_t neoswap_total_bytes = 0;  // mobilized + file fallback + archived
    const char* reason = "not_sampled";
};

constexpr std::uint64_t reserve_floor_bytes = 256 * MiB;
constexpr std::uint64_t reserve_ceiling_bytes = 768 * MiB;
constexpr std::uint64_t guest_reserve_floor_bytes = 1536 * MiB;
constexpr std::uint64_t growth_quantum_bytes = 64 * MiB;
constexpr std::uint64_t small_cpu_minimum_room_bytes = 128 * MiB;
constexpr std::uint64_t legacy_donor_floor_bytes = 512 * MiB;
constexpr std::uint64_t legacy_donor_reserve_bytes = 128 * MiB;
constexpr std::uint64_t relay_donor_reserve_bytes = 64 * MiB;

constexpr std::uint64_t clamp(std::uint64_t value, std::uint64_t low, std::uint64_t high) noexcept {
    return value < low ? low : value > high ? high : value;
}
constexpr std::uint64_t saturating_add(std::uint64_t a, std::uint64_t b) noexcept {
    return b > UINT64_MAX - a ? UINT64_MAX : a + b;
}
constexpr std::uint64_t operational_reserve(std::uint64_t physical_bytes, bool raised) noexcept {
    const auto base = clamp(physical_bytes / 16, reserve_floor_bytes, reserve_ceiling_bytes);
    return raised ? saturating_add(base, base) : base;
}

constexpr Decision decide(const Inputs& in, const Decision& previous) noexcept {
    Decision out{};
    out.mobilized_bytes = saturating_add(saturating_add(in.relay_guest_live_bytes, in.relay_host_live_bytes),
                                         in.donor_live_bytes);
    out.neoswap_total_bytes = saturating_add(saturating_add(out.mobilized_bytes, in.file_live_bytes),
                                             in.storage_archived_live_bytes);
    const bool os_pressure = in.dispatch_warning || in.system_pressure == Pressure::warning ||
                             in.system_pressure == Pressure::critical;
    out.operational_reserve_bytes = operational_reserve(in.physical_bytes, os_pressure || in.thermal_serious);
    // Guest objects keep a reserved share of the relay capacity even when host
    // loans are hungry: RPCS3 guest allocations must never fall back to files
    // because host data consumed the whole relay.
    out.guest_reserve_bytes = in.relay_guest_live_bytes > guest_reserve_floor_bytes
        ? in.relay_guest_live_bytes : guest_reserve_floor_bytes;
    if (!in.session_active) {
        out.state = State::idle;
        out.reason = "no_active_rpcs3_session";
        return out;
    }
    if (in.system_valid && in.system_usable_bytes > out.operational_reserve_bytes)
        out.growth_room_bytes = in.system_usable_bytes - out.operational_reserve_bytes;
    if (os_pressure) {
        out.state = State::pressure;
        out.reason = in.dispatch_warning ? "dispatch_memory_pressure" : "kernel_memory_pressure";
        out.host_loan_quota_bytes = in.relay_host_live_bytes; // retain, never grow
        out.storage_shrink_requested = true;
        out.donor_floor_bytes = 0;
        out.donor_reserve_bytes = 0;
        return out;
    }
    const std::uint64_t relay_free_for_host = in.relay_capacity_bytes > out.guest_reserve_bytes
        ? in.relay_capacity_bytes - out.guest_reserve_bytes : 0;
    if (in.relay_ready) {
        // Grow only by measured room; a ceiling never exceeds what the relay
        // can still back after the guest reserve.
        const auto desired = saturating_add(in.relay_host_live_bytes, out.growth_room_bytes);
        out.host_loan_quota_bytes = desired < relay_free_for_host ? desired : relay_free_for_host;
        if (out.host_loan_quota_bytes < in.relay_host_live_bytes)
            out.host_loan_quota_bytes = in.relay_host_live_bytes;
        out.host_loans_admitted = in.system_valid && out.growth_room_bytes >= growth_quantum_bytes &&
                                  out.host_loan_quota_bytes > in.relay_host_live_bytes;
    }
    // Donors are the fallback backing. While relay host loans are admitted the
    // pool keeps only a small reserve above its live loans; idle prepared
    // pages are retired instead of duplicating relay capacity.
    if (in.relay_ready && out.host_loans_admitted) {
        out.donor_floor_bytes = 0;
        out.donor_reserve_bytes = relay_donor_reserve_bytes;
    } else {
        out.donor_floor_bytes = legacy_donor_floor_bytes;
        out.donor_reserve_bytes = legacy_donor_reserve_bytes;
    }
    out.donor_growth_admitted = in.system_valid && out.growth_room_bytes >= growth_quantum_bytes;
    out.small_cpu_admitted = in.system_valid && in.system_usable_bytes >= small_cpu_minimum_room_bytes &&
        ((in.relay_ready && out.host_loans_admitted) || in.donors_available);
    const bool was_shrinking = previous.state == State::shrinking || previous.state == State::pressure;
    const bool below_reserve = in.system_valid && in.system_usable_bytes < out.operational_reserve_bytes;
    const bool recovered = in.system_valid &&
        in.system_usable_bytes >= saturating_add(out.operational_reserve_bytes, out.operational_reserve_bytes / 2);
    if (!in.system_valid) {
        out.state = State::holding;
        out.reason = "system_headroom_unknown";
        out.host_loans_admitted = false;
        out.donor_growth_admitted = false;
        out.small_cpu_admitted = false;
        out.host_loan_quota_bytes = in.relay_host_live_bytes;
    } else if (below_reserve || (was_shrinking && !recovered)) {
        out.state = State::shrinking;
        out.reason = below_reserve ? "system_room_below_operational_reserve" : "shrink_hysteresis";
        out.storage_shrink_requested = true;
        out.host_loans_admitted = false;
        out.donor_growth_admitted = false;
        out.small_cpu_admitted = false;
        out.host_loan_quota_bytes = in.relay_host_live_bytes;
    } else if (!in.relay_ready) {
        out.state = State::warming;
        out.reason = in.donors_available ? "relay_not_ready_donors_serve" : "relay_not_ready";
    } else if (out.host_loans_admitted) {
        out.state = State::growing;
        out.reason = "measured_room_available";
    } else {
        out.state = State::holding;
        out.reason = out.growth_room_bytes < growth_quantum_bytes ? "room_below_growth_quantum"
                                                                   : "relay_host_capacity_exhausted";
    }
    return out;
}

constexpr const char* state_name(State state) noexcept {
    switch (state) {
    case State::idle: return "idle";
    case State::warming: return "warming";
    case State::growing: return "growing";
    case State::holding: return "holding";
    case State::shrinking: return "shrinking";
    case State::pressure: return "pressure";
    }
    return "unknown";
}
} // namespace neostation::budget
