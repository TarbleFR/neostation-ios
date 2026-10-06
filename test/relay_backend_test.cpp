// SPDX-License-Identifier: MIT
// Behavioral tests with injected OS operations. These are NOT Darwin/iPhone
// residency evidence; a separate real-kernel probe exercises the same ABI.
#include "../native/neoswap-relay/Backend.h"
#include <algorithm>
#include <cassert>
#include <iostream>
#include <map>
#include <vector>

using neostation::relay::Backend;
using neostation::relay::Operations;
constexpr std::uint64_t page = NEOSWAP_RELAY_ALIGNMENT;
constexpr std::uintptr_t guest = 0x100000000ULL;

struct FakeOS {
    struct Entry { std::uint64_t bytes = 0; int refs = 1; std::vector<unsigned char> data; };
    struct Mapping {
        std::uint32_t port;
        std::uint64_t offset, bytes;
        std::uint32_t protection;
    };
    std::map<std::uint32_t, Entry> entries;
    std::map<std::uintptr_t, Mapping> mappings;
    std::uintptr_t next_address = 0x10000000000ULL;
    std::uint64_t budget = neostation::relay::maximum_capacity;
    int fail_retain = 0, fail_drop = 0, fail_map = 0, fail_unmap = 0, fail_zero = 0;
    int zero_calls = 0, unmap_calls = 0, fixed_replacements = 0, fixed_deallocation_holes = 0;
    void add(std::uint32_t port, std::uint64_t bytes) { entries[port].bytes = bytes; }
    void reserve(std::uintptr_t at, std::uint64_t bytes) { mappings[at] = {0, 0, bytes, NEOSWAP_RELAY_NONE}; }
    static bool fail(int& remaining) { if (!remaining) return false; --remaining; return true; }
    static int retain(void* context, std::uint32_t port) {
        auto& self = *static_cast<FakeOS*>(context);
        if (fail(self.fail_retain)) return 101;
        if (!self.entries.count(port)) return 102;
        ++self.entries[port].refs;
        return 0;
    }
    static int drop(void* context, std::uint32_t port) {
        auto& self = *static_cast<FakeOS*>(context);
        if (fail(self.fail_drop)) return 103;
        assert(self.entries.at(port).refs > 1);
        --self.entries.at(port).refs;
        return 0;
    }
    static int map(void* context, std::uint32_t port, std::uint64_t offset,
                   std::uint64_t bytes, std::uintptr_t target, std::uint32_t protection,
                   std::uintptr_t* mapped) {
        auto& self = *static_cast<FakeOS*>(context);
        if (fail(self.fail_map)) return 104;
        const auto& entry = self.entries.at(port);
        if (offset > entry.bytes || bytes > entry.bytes - offset) return 105;
        if (target) {
            // Fixed callers own a reservation; failures never erase it.
            if (!self.mappings.count(target) || self.mappings.at(target).bytes != bytes) return 106;
        } else {
            target = self.next_address;
            self.next_address += bytes + page;
        }
        self.mappings[target] = {port, offset, bytes, protection};
        *mapped = target;
        return 0;
    }
    static int unmap(void* context, std::uintptr_t address, std::uint64_t bytes, bool fixed) {
        auto& self = *static_cast<FakeOS*>(context);
        ++self.unmap_calls;
        if (fail(self.fail_unmap)) return 107;
        if (!self.mappings.count(address) || self.mappings.at(address).bytes != bytes) return 108;
        if (fixed) {
            // Single replacement: no instant where another user can take this
            // reserved virtual range. Production uses one mach_vm_map call.
            self.mappings[address] = {0, 0, bytes, NEOSWAP_RELAY_NONE};
            ++self.fixed_replacements;
        } else self.mappings.erase(address);
        return 0;
    }
    static int zero(void* context, std::uintptr_t address, std::uint64_t bytes) {
        auto& self = *static_cast<FakeOS*>(context);
        ++self.zero_calls;
        if (fail(self.fail_zero)) return 109;
        auto mapping = self.mappings.upper_bound(address);
        if (mapping == self.mappings.begin()) return 110;
        --mapping;
        const auto& view = mapping->second;
        const auto displacement = address - mapping->first;
        if (!view.port || displacement > view.bytes || bytes > view.bytes - displacement) return 111;
        auto& data = self.entries.at(view.port).data;
        const auto first = view.offset + displacement;
        if (first < data.size()) {
            const auto finish = std::min<std::uint64_t>(first + bytes, data.size());
            std::fill(data.begin() + first, data.begin() + finish, 0);
        }
        return 0;
    }
    static std::uint64_t headroom(void* context) { return static_cast<FakeOS*>(context)->budget; }
    static Operations operations() { return {retain, drop, map, unmap, zero, headroom}; }
    void write(void* view, std::uint64_t index, unsigned char value) {
        const auto& mapping = mappings.at(reinterpret_cast<std::uintptr_t>(view));
        assert(mapping.protection == NEOSWAP_RELAY_READ_WRITE && index < mapping.bytes);
        auto& data = entries.at(mapping.port).data;
        if (data.size() <= mapping.offset + index) data.resize(mapping.offset + index + 1);
        data[mapping.offset + index] = value;
    }
    unsigned char read(void* view, std::uint64_t index) const {
        const auto& mapping = mappings.at(reinterpret_cast<std::uintptr_t>(view));
        assert(mapping.protection & NEOSWAP_RELAY_READ);
        assert(index < mapping.bytes);
        const auto& data = entries.at(mapping.port).data;
        return mapping.offset + index < data.size() ? data[mapping.offset + index] : 0;
    }
};
struct Fixture {
    FakeOS os;
    Backend backend{FakeOS::operations(), &os};
    explicit Fixture(std::uint64_t bytes = 4 * page) {
        os.add(42, bytes);
        assert(backend.configure(1) == NEOSWAP_RELAY_OK);
        assert(backend.adopt(42, bytes, 1234, 1) == NEOSWAP_RELAY_OK);
    }
    NeoSwapRelayStats stats() {
        NeoSwapRelayStats result{};
        result.struct_size = sizeof(result);
        assert(backend.snapshot(&result) == NEOSWAP_RELAY_OK);
        return result;
    }
    std::uint64_t create(std::uint64_t bytes = page) {
        std::uint64_t token = 0;
        assert(backend.create(0, bytes, &token) == NEOSWAP_RELAY_OK && token);
        return token;
    }
};

static void alias_identity_and_lifetime() {
    Fixture f;
    const auto token = f.create();
    void *writable = nullptr, *readonly = nullptr, *anywhere = nullptr;
    f.os.reserve(guest, page);
    f.os.reserve(guest + 2 * page, page);
    assert(f.backend.map(token, reinterpret_cast<void*>(guest), NEOSWAP_RELAY_READ_WRITE, &writable) == 0);
    assert(f.backend.map(token, reinterpret_cast<void*>(guest + 2 * page), NEOSWAP_RELAY_READ, &readonly) == 0);
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &anywhere) == 0);
    f.os.write(writable, 0, 0x71);
    f.os.write(anywhere, page - 1, 0x93);
    assert(f.os.read(readonly, 0) == 0x71 && f.os.read(readonly, page - 1) == 0x93);
    assert(f.stats().live_bytes == page && f.stats().mapped_alias_bytes == 3 * page);
    assert(f.backend.release(token) == NEOSWAP_RELAY_BUSY && f.os.zero_calls == 0);
    assert(f.backend.shutdown() == NEOSWAP_RELAY_BUSY);
    assert(f.backend.unmap(token, writable) == 0);
    assert(f.os.mappings.at(guest).port == 0 && f.os.mappings.at(guest).protection == NEOSWAP_RELAY_NONE);
    assert(f.os.read(readonly, 0) == 0x71); // A first alias removal must never zero the object.
    assert(f.backend.unmap(token, readonly) == 0);
    assert(f.backend.unmap(token, anywhere) == 0);
    assert(!f.os.mappings.count(reinterpret_cast<std::uintptr_t>(anywhere)));
    assert(f.backend.release(token) == 0 && f.os.zero_calls == 1);
    assert(f.stats().live_bytes == 0 && f.stats().object_count == 0 && f.stats().alias_count == 0);
    assert(f.backend.release(token) == NEOSWAP_RELAY_UNKNOWN);
    const auto replacement = f.create();
    assert(replacement != token);
    assert(f.backend.map(replacement, nullptr, NEOSWAP_RELAY_READ, &readonly) == 0);
    assert(f.os.read(readonly, 0) == 0 && f.os.read(readonly, page - 1) == 0);
    assert(f.backend.unmap(replacement, readonly) == 0 && f.backend.release(replacement) == 0);
    assert(f.os.fixed_replacements == 2 && f.os.fixed_deallocation_holes == 0);
    assert(f.backend.shutdown() == 0 && f.os.entries.at(42).refs == 1);
    assert(f.os.mappings.size() == 2); // Only the caller's two reservations remain.
}
static void failures_do_not_free_live_ranges() {
    Fixture f;
    const auto token = f.create();
    f.os.reserve(guest, page);
    void* mapped = nullptr;
    f.os.fail_map = 1;
    assert(f.backend.map(token, reinterpret_cast<void*>(guest), 3, &mapped) == NEOSWAP_RELAY_MAPPING);
    assert(!mapped && f.os.mappings.at(guest).port == 0 && f.stats().alias_count == 0);
    assert(f.stats().last_os_error == 104);
    assert(f.backend.map(token, reinterpret_cast<void*>(guest), 3, &mapped) == 0);
    f.os.write(mapped, 5, 0xA4);
    f.os.fail_unmap = 1;
    assert(f.backend.unmap(token, mapped) == NEOSWAP_RELAY_MAPPING);
    assert(f.stats().alias_count == 1 && f.os.read(mapped, 5) == 0xA4);
    assert(f.backend.release(token) == NEOSWAP_RELAY_BUSY && !f.os.zero_calls);
    assert(f.backend.unmap(token, mapped) == 0);
    assert(f.backend.unmap(token, mapped) == NEOSWAP_RELAY_UNKNOWN);
    f.os.fail_zero = 1;
    assert(f.backend.release(token) == NEOSWAP_RELAY_CLEANUP);
    assert(f.stats().object_count == 1 && f.stats().live_bytes == page);
    const auto other = f.create();
    assert(f.backend.map(other, nullptr, 3, &mapped) == 0);
    assert(f.os.read(mapped, 5) == 0); // The failed scrub interval was not reused.
    assert(f.backend.unmap(other, mapped) == 0 && f.backend.release(other) == 0);
    assert(f.backend.release(token) == 0);
    assert(f.stats().os_error_count == 3);
}
static void guards_and_pressure() {
    Fixture f;
    std::uint64_t token = 99;
    // Owner 1 is the host-loan owner; any other owner stays unsupported. The
    // guest-only mask from the fixture keeps host loans disabled here.
    assert(f.backend.configure(4) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.configure(1 | 8) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.create(1, page, &token) == NEOSWAP_RELAY_DISABLED && token == 0);
    assert(f.backend.create(2, page, &token) == NEOSWAP_RELAY_DISABLED && token == 0);
    assert(f.backend.create(0, page - 1, &token) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.create(0, 0, &token) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.create(32, page, &token) == NEOSWAP_RELAY_INVALID);
    f.os.budget = page - 1;
    assert(f.backend.create(0, page, &token) == NEOSWAP_RELAY_PRESSURE);
    f.os.budget = 4 * page;
    f.backend.set_pressure(true);
    assert(!f.backend.enabled(0));
    assert(f.backend.create(0, page, &token) == NEOSWAP_RELAY_PRESSURE);
    f.backend.set_pressure(false);
    token = f.create();
    assert(f.backend.configure(0) == NEOSWAP_RELAY_BUSY);
    void* mapped = nullptr;
    assert(f.backend.map(token, nullptr, 7, &mapped) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.map(token, nullptr, 2, &mapped) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.map(token, reinterpret_cast<void*>(guest + 1), 3, &mapped) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.map(token, reinterpret_cast<void*>(UINTPTR_MAX - page + 1), 3, &mapped) == NEOSWAP_RELAY_INVALID);
    const auto cleaning = f.os.mappings.begin()->first;
    assert(f.backend.map(token, reinterpret_cast<void*>(cleaning), 3, &mapped) == NEOSWAP_RELAY_INVALID);
    f.backend.set_pressure(true);
    assert(f.backend.map(token, nullptr, 3, &mapped) == NEOSWAP_RELAY_PRESSURE);
    f.backend.set_pressure(false);
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_NONE, &mapped) == 0);
    void* duplicate = nullptr;
    assert(f.backend.map(token, mapped, 3, &duplicate) == NEOSWAP_RELAY_INVALID);
    f.backend.set_pressure(true);
    assert(f.backend.unmap(token, mapped) == 0 && f.backend.release(token) == 0);
    f.backend.set_pressure(false);
    const auto beforeScope = f.stats();
    const auto mappingsBeforeScope = f.os.mappings.size();
    // Owners 2..5 are legacy allocator slots that the relay never serves;
    // owner 1 (host loans) is covered by host_loan_owner_quota_protects_guest_share.
    for (uint32_t owner = 2; owner < 6; ++owner) {
        assert(f.backend.configure(1U | (1U << owner)) == NEOSWAP_RELAY_INVALID);
        assert(!f.backend.enabled(owner) && f.backend.enabled(0));
        token = 99;
        assert(f.backend.create(owner, page, &token) == NEOSWAP_RELAY_DISABLED && !token);
        assert(f.stats().enabled_owner_mask == 1U);
        assert(f.stats().retained_capacity_bytes == beforeScope.retained_capacity_bytes);
        assert(f.stats().object_count == beforeScope.object_count);
        assert(f.os.mappings.size() == mappingsBeforeScope);
    }
    assert(f.backend.configure(1) == 0 && f.backend.enabled(0));
    NeoSwapRelayStats too_small{};
    assert(f.backend.snapshot(&too_small) == NEOSWAP_RELAY_INVALID);
    assert(!NeoSwap_GetRelayAPI(2));
    const auto* api = NeoSwap_GetRelayAPI(1);
    assert(api && api->struct_size == sizeof(*api) && api->abi_version == 1);
}
static void coalescing_and_quotas() {
    Fixture f;
    const auto a = f.create(), b = f.create(), c = f.create(), d = f.create();
    std::uint64_t token = 0;
    assert(f.backend.create(0, page, &token) == NEOSWAP_RELAY_QUOTA);
    assert(f.backend.release(a) == 0 && f.backend.release(c) == 0);
    assert(f.backend.create(0, 2 * page, &token) == NEOSWAP_RELAY_QUOTA);
    assert(f.backend.release(b) == 0);
    token = f.create(3 * page); // Adjacent free intervals must coalesce.
    assert(f.backend.release(d) == 0 && f.backend.release(token) == 0);
    token = f.create(4 * page);
    assert(f.backend.release(token) == 0);
    assert(f.stats().peak_live_bytes == 4 * page);
    assert(f.backend.adopt(42, page, 1234, 1) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.adopt(43, page, 0, 2) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.adopt(43, page, 1234, 0) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.configure(1, 3 * page) == NEOSWAP_RELAY_QUOTA);
    assert(f.backend.configure(1, neostation::relay::maximum_capacity + page) == NEOSWAP_RELAY_INVALID);
    FakeOS os;
    Backend large(FakeOS::operations(), &os);
    const auto half = neostation::relay::maximum_segment_bytes;
    os.add(1, half); os.add(2, half); os.add(3, page);
    assert(large.configure(1, 2 * half) == 0);
    assert(large.adopt(1, half, 7, 9) == 0 && large.adopt(2, half, 7, 9) == 0);
    assert(large.adopt(3, page, 7, 9) == NEOSWAP_RELAY_QUOTA);
    assert(os.entries.at(3).refs == 1);
    assert(large.shutdown() == 0);
}
static void cleanup_failures_are_retained_for_retry() {
    FakeOS os;
    Backend backend(FakeOS::operations(), &os);
    os.add(1, page);
    assert(backend.configure(1) == 0);
    os.fail_retain = 1;
    assert(backend.adopt(1, page, 1, 1) == NEOSWAP_RELAY_MAPPING && os.entries.at(1).refs == 1);
    os.fail_map = 1; os.fail_drop = 1;
    assert(backend.adopt(1, page, 1, 1) == NEOSWAP_RELAY_CLEANUP);
    NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats);
    assert(backend.snapshot(&stats) == 0);
    assert(!stats.capacity_bytes && stats.retained_capacity_bytes == page && stats.pending_cleanup_entries == 1);
    assert(os.entries.at(1).refs == 2);
    assert(backend.adopt(1, page, 1, 1) == NEOSWAP_RELAY_INVALID);
    assert(backend.shutdown() == 0 && os.entries.at(1).refs == 1);
    assert(backend.configure(1) == 0 && backend.adopt(1, page, 1, 2) == 0);
    os.fail_unmap = 1;
    assert(backend.shutdown() == NEOSWAP_RELAY_CLEANUP);
    assert(os.entries.at(1).refs == 2 && os.mappings.size() == 1);
    assert(backend.configure(1) == NEOSWAP_RELAY_BUSY);
    assert(backend.snapshot(&stats) == 0 && stats.capacity_bytes == 0 && stats.retained_capacity_bytes == page);
    os.fail_drop = 1;
    assert(backend.shutdown() == NEOSWAP_RELAY_CLEANUP);
    assert(os.mappings.empty() && os.entries.at(1).refs == 2);
    assert(backend.shutdown() == 0 && os.entries.at(1).refs == 1);
    assert(backend.snapshot(&stats) == 0 && !stats.retained_capacity_bytes && !stats.pending_cleanup_entries);
}
static void repeated_lifecycles_have_no_stale_tokens() {
    Fixture f;
    std::uint64_t previous = 0;
    for (int iteration = 0; iteration < 100; ++iteration) {
        const auto token = f.create();
        void* mapped = nullptr;
        if (previous) assert(f.backend.map(previous, nullptr, 3, &mapped) == NEOSWAP_RELAY_UNKNOWN);
        assert(f.backend.map(token, nullptr, 3, &mapped) == 0);
        f.os.write(mapped, page - 1, 0x33);
        assert(f.backend.unmap(token, mapped) == 0 && f.backend.release(token) == 0);
        previous = token;
    }
    assert(f.stats().object_count == 0 && f.stats().alias_count == 0 && f.os.mappings.size() == 1);
}
static void retirement_retries_only_quiesced_objects() {
    Fixture f;
    const auto retired = f.create(), active = f.create();
    void *fixed = nullptr, *other = nullptr, *still_active = nullptr;
    f.os.reserve(guest, page);
    assert(f.backend.map(retired, nullptr, 3, &other) == 0);
    assert(f.backend.map(retired, reinterpret_cast<void*>(guest), 3, &fixed) == 0);
    assert(f.backend.map(active, nullptr, 3, &still_active) == 0);
    f.os.write(still_active, 13, 0x4A);
    f.os.fail_unmap = 1;
    assert(f.backend.retire(retired) == NEOSWAP_RELAY_CLEANUP);
    assert(f.stats().retiring_object_count == 1 && f.stats().object_count == 2);
    assert(f.stats().alias_count == 2 && !f.os.zero_calls);
    void* forbidden = nullptr;
    assert(f.backend.map(retired, nullptr, 3, &forbidden) == NEOSWAP_RELAY_BUSY);
    f.os.fail_zero = 1;
    assert(f.backend.collect() == NEOSWAP_RELAY_CLEANUP);
    assert(f.stats().alias_count == 1 && f.stats().retiring_object_count == 1);
    assert(f.backend.collect() == 0 && !f.stats().retiring_object_count);
    assert(f.stats().object_count == 1 && f.stats().live_bytes == page && f.stats().alias_count == 1);
    assert(f.os.read(still_active, 13) == 0x4A); // Collector never touches active game users.
    assert(f.os.mappings.at(guest).port == 0);
    assert(f.backend.retire(retired) == NEOSWAP_RELAY_UNKNOWN);
    assert(f.backend.retire(active) == 0 && f.backend.collect() == 0);
}
static void failed_fixed_retirement_never_clobbers_reused_guest_address() {
    Fixture f;
    const auto token = f.create(), active = f.create();
    f.os.reserve(guest, page);
    void* view = nullptr;
    assert(f.backend.map(token, reinterpret_cast<void*>(guest), 3, &view) == 0);
    f.os.write(view, 0, 0x71);
    f.os.fail_unmap = 1;
    assert(f.backend.retire(token) == NEOSWAP_RELAY_CLEANUP);
    assert(f.stats().quarantined_fixed_alias_count == 1 && f.stats().retiring_object_count == 1);
    assert(!f.backend.enabled(0));
    std::uint64_t new_token = 0;
    assert(f.backend.create(0, page, &new_token) == NEOSWAP_RELAY_DISABLED && !new_token);
    // Already live, unrelated guest data remains usable through its original
    // token; disabling future objects must not break an in-flight owner.
    void* active_alias = nullptr;
    assert(f.backend.map(active, nullptr, 3, &active_alias) == 0);
    f.os.write(active_alias, 0, 0x61);
    assert(f.os.read(active_alias, 0) == 0x61);
    assert(f.backend.unmap(active, active_alias) == 0 && f.backend.release(active) == 0);
    const int attempts = f.os.unmap_calls;
    const int scrubbed_before = f.os.zero_calls;
    // After the old guest object dies, another allocator can replace the range.
    // A delayed PROT_NONE overwrite would now corrupt the new user's mapping.
    f.os.add(999, page);
    f.os.mappings[guest] = {999, 0, page, NEOSWAP_RELAY_READ_WRITE};
    f.os.write(view, 0, 0xE2);
    assert(f.backend.collect() == NEOSWAP_RELAY_CLEANUP);
    assert(f.backend.retire(token) == NEOSWAP_RELAY_CLEANUP);
    assert(f.backend.unmap(token, view) == NEOSWAP_RELAY_BUSY);
    assert(f.os.unmap_calls == attempts && f.os.read(view, 0) == 0xE2);
    assert(f.stats().last_os_error == 0); // Explicit rejected unmap supersedes diagnostics.
    assert(f.backend.collect() == NEOSWAP_RELAY_CLEANUP && f.stats().last_os_error == 107);
    assert(f.stats().os_error_count == 1 && f.os.zero_calls == scrubbed_before);
    assert(f.stats().live_bytes == page && f.backend.shutdown() == NEOSWAP_RELAY_BUSY);
}
static void every_fixed_alias_is_attempted_before_retire_returns() {
    Fixture f;
    const auto token = f.create();
    for (int i = 0; i < 70; ++i) {
        const auto target = guest + static_cast<std::uintptr_t>(i) * 2 * page;
        f.os.reserve(target, page);
        void* alias = nullptr;
        assert(f.backend.map(token, reinterpret_cast<void*>(target), 3, &alias) == 0);
    }
    f.os.fail_unmap = 70;
    assert(f.backend.retire(token) == NEOSWAP_RELAY_CLEANUP);
    assert(f.stats().quarantined_fixed_alias_count == 70 && f.os.unmap_calls == 70);
    assert(f.backend.collect() == NEOSWAP_RELAY_CLEANUP && f.os.unmap_calls == 70);
    assert(f.os.zero_calls == 0);
}
static void retirement_is_bounded_and_fair() {
    Fixture f(8 * page);
    const auto token = f.create();
    for (int i = 0; i < 70; ++i) {
        void* alias = nullptr;
        assert(f.backend.map(token, nullptr, 3, &alias) == 0);
    }
    assert(f.backend.retire(token) == NEOSWAP_RELAY_BUSY);
    assert(f.stats().alias_count == 6 && f.stats().retiring_object_count == 1);
    assert(f.backend.collect() == 0 && !f.stats().alias_count && !f.stats().retiring_object_count);
    std::uint64_t tokens[6]{};
    for (auto& value : tokens) value = f.create();
    // Scrub failure keeps all six tokens in the backend after callers die.
    f.os.fail_zero = 6;
    for (auto value : tokens) assert(f.backend.retire(value) == NEOSWAP_RELAY_CLEANUP);
    f.os.fail_zero = 4;
    assert(f.backend.collect() == NEOSWAP_RELAY_CLEANUP); // First four fail once more.
    assert(f.stats().retiring_object_count == 6);
    assert(f.backend.collect() == NEOSWAP_RELAY_BUSY); // Round-robin reaches last two too.
    assert(f.stats().retiring_object_count == 2);
    assert(f.backend.collect() == 0 && !f.stats().object_count);
}
static void eight_gibibyte_capacity_keeps_bounded_tokens_and_wide_counters() {
    // Virtual fixture metadata only: no 8-GiB physical allocation and no claim
    // of OS residency. Real-device pressure still governs every create/map.
    FakeOS os;
    Backend backend(FakeOS::operations(), &os);
    constexpr auto segment = neostation::relay::maximum_segment_bytes;
    constexpr auto capacity = neostation::relay::maximum_capacity;
    static_assert(segment == 512ULL * 1024 * 1024 && capacity == 8ULL * 1024 * 1024 * 1024);
    assert(backend.configure(1, capacity) == 0);
    os.add(999, segment + page);
    assert(backend.adopt(999, segment + page, 17, 41) == NEOSWAP_RELAY_INVALID);
    assert(os.entries.at(999).refs == 1);
    for (std::uint32_t port = 1; port <= 16; ++port) {
        os.add(port, segment);
        assert(backend.adopt(port, segment, 17, 41) == 0);
    }
    os.add(17, page);
    assert(backend.adopt(17, page, 17, 41) == NEOSWAP_RELAY_QUOTA);
    assert(os.entries.at(17).refs == 1);
    std::uint64_t tokens[16]{};
    void* views[16][2]{};
    std::uint64_t invalid = 0;
    assert(backend.create(0, segment + page, &invalid) == NEOSWAP_RELAY_QUOTA && !invalid);
    assert(backend.create(0, capacity, &invalid) == NEOSWAP_RELAY_QUOTA && !invalid);
    assert(backend.create(0, UINT64_MAX, &invalid) == NEOSWAP_RELAY_INVALID && !invalid);
    for (std::size_t i = 0; i < 16; ++i) {
        assert(backend.create(0, segment, &tokens[i]) == 0);
        assert(backend.map(tokens[i], nullptr, NEOSWAP_RELAY_READ_WRITE, &views[i][0]) == 0);
        assert(backend.map(tokens[i], nullptr, NEOSWAP_RELAY_READ, &views[i][1]) == 0);
        const auto& first = os.mappings.at(reinterpret_cast<std::uintptr_t>(views[i][0]));
        const auto& second = os.mappings.at(reinterpret_cast<std::uintptr_t>(views[i][1]));
        assert(first.port == i + 1 && second.port == first.port && first.offset == 0 && second.offset == 0);
        for (std::size_t previous = 0; previous < i; ++previous) assert(tokens[previous] != tokens[i]);
    }
    NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats);
    assert(backend.snapshot(&stats) == 0);
    assert(stats.capacity_bytes == capacity && stats.retained_capacity_bytes == capacity && stats.live_bytes == capacity);
    assert(stats.mapped_alias_bytes == capacity * 2 && stats.alias_count == 32 && stats.object_count == 16);
    assert(backend.create(0, page, &invalid) == NEOSWAP_RELAY_QUOTA && !invalid);
    for (auto token : tokens) assert(backend.retire(token) == 0);
    assert(backend.snapshot(&stats) == 0 && !stats.live_bytes && !stats.alias_count && !stats.object_count);
    assert(stats.capacity_bytes == capacity && stats.peak_live_bytes == capacity);
    os.budget = segment - 1;
    assert(backend.create(0, segment, &invalid) == NEOSWAP_RELAY_PRESSURE && !invalid);
    os.budget = capacity;
    // Cross the 14-bit slot index boundary without allocating backing data.
    // Reusing an object slot must never validate its previous generation token.
    std::uint64_t first_token = 0, reused_index_token = 0;
    for (unsigned i = 0; i <= 16384; ++i) {
        std::uint64_t token = 0;
        assert(backend.create(0, page, &token) == 0);
        if (i == 0) first_token = token;
        if (i == 16384) reused_index_token = token;
        assert(backend.release(token) == 0);
    }
    assert(first_token != reused_index_token && (first_token & 16383) == (reused_index_token & 16383));
    void* stale = nullptr;
    assert(backend.map(first_token, nullptr, NEOSWAP_RELAY_READ, &stale) == NEOSWAP_RELAY_UNKNOWN);
    assert(backend.shutdown() == 0 && os.mappings.empty());
    for (const auto& item : os.entries) assert(item.second.refs == 1 && item.second.data.empty());
}
static void published_backing_survives_pressure() {
    Fixture f;
    const auto token = f.create(2 * page);
    void *writer = nullptr, *reader = nullptr;
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &writer) == 0);
    f.os.write(writer, 0, 0xA1);
    f.os.write(writer, 2 * page - 1, 0xE9);
    // Reproduces Build393: an already published object cannot switch to file
    // fallback, but its second map was rejected by the pressure/headroom gate.
    f.backend.set_pressure(true);
    f.os.budget = 0;
    const auto before = f.stats();
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_READ, &reader) == 0);
    assert(f.os.read(reader, 0) == 0xA1 && f.os.read(reader, 2 * page - 1) == 0xE9);
    assert(f.stats().live_bytes == before.live_bytes && f.stats().object_count == before.object_count);
    assert(f.stats().alias_count == before.alias_count + 1);
    std::uint64_t fresh = 99;
    assert(f.backend.create(0, page, &fresh) == NEOSWAP_RELAY_PRESSURE && !fresh);
    assert(!f.backend.enabled(0)); // Pressure still blocks new backing.
    void* failed = reinterpret_cast<void*>(1);
    f.os.fail_map = 1;
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_READ, &failed) == NEOSWAP_RELAY_MAPPING && !failed);
    assert(f.stats().last_os_error == 104 && f.stats().alias_count == before.alias_count + 1);
    assert(f.os.read(writer, 0) == 0xA1); // Kernel failure did not corrupt old data.
    assert(f.backend.unmap(token, reader) == 0 && f.backend.unmap(token, writer) == 0);
    // Temporarily having no view must NOT turn a published object back into
    // an uncommitted allocation. Remapping the same retained backing is valid.
    assert(f.backend.map(token, nullptr, NEOSWAP_RELAY_READ, &reader) == 0);
    assert(f.os.read(reader, 2 * page - 1) == 0xE9);
    assert(f.backend.unmap(token, reader) == 0 && f.backend.release(token) == 0);
    f.backend.set_pressure(false);
    f.os.budget = 4 * page;
    const auto replacement = f.create();
    f.backend.set_pressure(true);
    // A reused slot has a new token and must pass its first-map admission gate.
    assert(f.backend.map(replacement, nullptr, 3, &reader) == NEOSWAP_RELAY_PRESSURE && !reader);
    assert(f.backend.release(replacement) == 0);
    const auto evidence = f.backend.pressure_diagnostics();
    assert(evidence.transitions == 3 && evidence.existing_alias_maps == 2);
    assert(evidence.create_refusals == 1 && evidence.first_map_refusals == 1);
    assert(evidence.map_failures == 1);
    // A later success/refusal cannot erase the original kernel mapping error
    // count. The last failure remains typed as a first-map pressure refusal.
    assert(evidence.last_map_result == NEOSWAP_RELAY_PRESSURE && evidence.last_map_os_error == 0);
}

static void host_loan_owner_quota_protects_guest_share() {
    using neostation::relay::host_loan_owner;
    Fixture f(8 * page);
    assert(f.backend.configure(neostation::relay::supported_owner_mask) == NEOSWAP_RELAY_OK);
    assert(f.backend.enabled(0) && f.backend.enabled(host_loan_owner) && !f.backend.enabled(2));
    assert(f.backend.set_owner_quota(2, page) == NEOSWAP_RELAY_INVALID);
    assert(f.backend.set_owner_quota(host_loan_owner, 2 * page) == NEOSWAP_RELAY_OK);
    std::uint64_t host_a = 0, host_b = 0, host_c = 0, guest = 0;
    assert(f.backend.create(host_loan_owner, page, &host_a) == NEOSWAP_RELAY_OK && host_a);
    assert(f.backend.create(host_loan_owner, page, &host_b) == NEOSWAP_RELAY_OK && host_b);
    // The quota refuses the third host object while capacity remains; guest
    // objects are never charged against the host quota.
    assert(f.backend.create(host_loan_owner, page, &host_c) == NEOSWAP_RELAY_QUOTA && !host_c);
    assert(f.backend.create(0, page, &guest) == NEOSWAP_RELAY_OK && guest);
    auto evidence = f.backend.pressure_diagnostics();
    assert(evidence.owner_live_bytes[0] == page && evidence.owner_live_bytes[host_loan_owner] == 2 * page);
    assert(evidence.owner_peak_bytes[host_loan_owner] == 2 * page && evidence.quota_refusals == 1);
    assert(evidence.owner_quota_bytes[host_loan_owner] == 2 * page && evidence.owner_quota_bytes[0] == 0);
    // Lowering the quota below the live value refuses growth without revoking.
    assert(f.backend.set_owner_quota(host_loan_owner, page) == NEOSWAP_RELAY_OK);
    void* view = nullptr;
    assert(f.backend.map(host_a, nullptr, NEOSWAP_RELAY_READ_WRITE, &view) == NEOSWAP_RELAY_OK && view);
    f.os.write(view, 0, 0x4C);
    assert(f.backend.create(host_loan_owner, page, &host_c) == NEOSWAP_RELAY_QUOTA && !host_c);
    assert(f.os.read(view, 0) == 0x4C);
    assert(f.backend.unmap(host_a, view) == NEOSWAP_RELAY_OK && f.backend.release(host_a) == NEOSWAP_RELAY_OK);
    evidence = f.backend.pressure_diagnostics();
    assert(evidence.owner_live_bytes[host_loan_owner] == page && evidence.quota_refusals == 2);
    // Zero quota means capacity-bound only; a released interval is reusable.
    assert(f.backend.set_owner_quota(host_loan_owner, 0) == NEOSWAP_RELAY_OK);
    assert(f.backend.create(host_loan_owner, page, &host_c) == NEOSWAP_RELAY_OK && host_c);
    assert(f.backend.create(host_loan_owner, 5 * page, &host_a) == NEOSWAP_RELAY_OK && host_a);
    assert(f.stats().live_bytes == 8 * page && f.stats().object_count == 4);
    for (auto token : {host_a, host_b, host_c, guest}) assert(f.backend.release(token) == NEOSWAP_RELAY_OK);
    evidence = f.backend.pressure_diagnostics();
    assert(!evidence.owner_live_bytes[0] && !evidence.owner_live_bytes[host_loan_owner]);
    assert(evidence.owner_peak_bytes[host_loan_owner] == 7 * page);
    assert(f.backend.shutdown() == NEOSWAP_RELAY_OK);
}

int main() {
    host_loan_owner_quota_protects_guest_share();
    published_backing_survives_pressure();
    alias_identity_and_lifetime();
    failures_do_not_free_live_ranges();
    guards_and_pressure();
    coalescing_and_quotas();
    cleanup_failures_are_retained_for_retry();
    repeated_lifecycles_have_no_stale_tokens();
    retirement_retries_only_quiesced_objects();
    failed_fixed_retirement_never_clobbers_reused_guest_address();
    every_fixed_alias_is_attempted_before_retire_returns();
    retirement_is_bounded_and_fair();
    eight_gibibyte_capacity_keeps_bounded_tokens_and_wide_counters();
    std::cout << "relay backend: alias identity, fixed reservations, failure ownership, zeroing, pressure, coalescing, deferred retirement, host-loan owner quotas and lifecycle checks passed\n";
}
