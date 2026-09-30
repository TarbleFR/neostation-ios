// SPDX-License-Identifier: MIT
// Adapted from Guest Page Relay; see LICENSE in this directory.
#include "Backend.h"
#include <algorithm>
#include <array>
#include <bitset>
#include <cerrno>
#include <limits>
#include <mutex>
#include <new>
#if defined(__APPLE__)
#if __has_include("../Donation/Broker.h")
#include "../Donation/Broker.h"
#else
#include "../neoswap-donation/Broker.h"
#endif
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#endif

namespace neostation::relay {
namespace {
constexpr std::uint64_t alignment = NEOSWAP_RELAY_ALIGNMENT;
constexpr std::size_t maximum_entries = 16;
// More retained named-object capacity does not multiply host metadata. Large
// segments still share the original bounded token/alias tables; exhaustion
// takes the client's ordinary allocator fallback before any relay view exists.
constexpr std::size_t maximum_objects = 16384;
constexpr std::size_t maximum_segment_pages = maximum_segment_bytes / alignment;
constexpr std::size_t maximum_aliases = maximum_objects * 4;
constexpr std::uint64_t index_mask = maximum_objects - 1;
constexpr unsigned token_shift = 14;
static_assert((1U << token_shift) == maximum_objects);
static_assert(maximum_entries * maximum_segment_bytes == maximum_capacity);
bool valid_size(std::uint64_t bytes) noexcept {
    return bytes && bytes <= maximum_capacity && bytes % alignment == 0;
}
bool overlaps(std::uintptr_t a, std::uint64_t ab, std::uintptr_t b, std::uint64_t bb) noexcept {
    return a < b + bb && b < a + ab;
}
bool valid_range(std::uintptr_t address, std::uint64_t bytes) noexcept {
    return address && address % alignment == 0 &&
        bytes <= std::numeric_limits<std::uintptr_t>::max() - address;
}
} // namespace

struct Backend::State {
    struct Entry {
        std::uint32_t port = 0;
        std::int32_t pid = 0;
        std::uint64_t generation = 0, bytes = 0;
        std::uintptr_t window = 0;
        bool ready = false;
        // A bitmap naturally coalesces adjacent free intervals; no allocation
        // or fallible metadata growth occurs while returning a guest object.
        std::bitset<maximum_segment_pages> occupied;
    };
    struct Object {
        std::uint64_t token = 0, bytes = 0, offset = 0;
        std::uint32_t entry = 0, owner = 0, aliases = 0;
        bool retiring = false;
        int quarantine_error = 0;
    };
    struct Alias {
        std::uint64_t token = 0, bytes = 0;
        std::uintptr_t address = 0;
        bool fixed = false;
        bool quarantined = false;
    };
    const Operations ops;
    void* context;
    std::mutex mutex;
    std::array<Entry, maximum_entries> entries{};
    std::array<Object, maximum_objects> objects{};
    std::array<Alias, maximum_aliases> aliases{};
    NeoSwapRelayStats stats{};
    std::uint64_t capacity_limit = maximum_capacity, next_serial = 1;
    std::size_t next_object = 0, next_alias = 0, next_collect = 0;
    bool closing = false;
    State(const Operations& operations, void* user) noexcept : ops(operations), context(user) {
        stats.struct_size = sizeof(stats);
        stats.abi_version = NEOSWAP_RELAY_ABI;
    }
    bool available() const noexcept {
        return ops.retain && ops.drop && ops.map && ops.unmap && ops.zero && ops.headroom;
    }
    int fail(int result, int error = 0) noexcept {
        stats.last_result = result;
        stats.last_os_error = error;
        ++stats.rejection_count;
        if (error) ++stats.os_error_count;
        return result;
    }
    int success() noexcept {
        stats.last_result = NEOSWAP_RELAY_OK;
        stats.last_os_error = 0;
        return NEOSWAP_RELAY_OK;
    }
    void recount_entries() noexcept {
        stats.capacity_bytes = stats.retained_capacity_bytes = stats.entry_count =
            stats.pending_cleanup_entries = 0;
        for (const auto& entry : entries) if (entry.port) {
            stats.retained_capacity_bytes += entry.bytes;
            if (entry.ready) {
                stats.capacity_bytes += entry.bytes;
                ++stats.entry_count;
            } else ++stats.pending_cleanup_entries;
        }
    }
    Object* object(std::uint64_t token) noexcept {
        auto& candidate = objects[token & index_mask];
        return token && candidate.token == token ? &candidate : nullptr;
    }
    int cleanup(Entry& entry) noexcept {
        entry.ready = false;
        if (entry.window) {
            const int result = ops.unmap(context, entry.window, entry.bytes, false);
            if (result) return fail(NEOSWAP_RELAY_CLEANUP, result);
            entry.window = 0;
        }
        if (entry.port) {
            const int result = ops.drop(context, entry.port);
            if (result) return fail(NEOSWAP_RELAY_CLEANUP, result);
        }
        entry = {};
        return NEOSWAP_RELAY_OK;
    }
    int finish_object(Object& object) noexcept {
        if (object.aliases) return fail(NEOSWAP_RELAY_BUSY);
        auto& entry = entries[object.entry];
        const int result = ops.zero(context, entry.window + object.offset, object.bytes);
        if (result) return fail(NEOSWAP_RELAY_CLEANUP, result);
        const auto first = object.offset / alignment;
        for (std::size_t n = 0; n < object.bytes / alignment; ++n) entry.occupied.reset(first + n);
        stats.live_bytes -= object.bytes;
        --stats.object_count;
        if (object.retiring) --stats.retiring_object_count;
        object = {};
        return success();
    }
    int collect_object(Object& object, unsigned& remaining_unmaps, bool initial_retirement = false) noexcept {
        int failure = NEOSWAP_RELAY_OK;
        for (auto& alias : aliases) {
            if (alias.token != object.token) continue;
            if (alias.quarantined) continue;
            // No deferred fixed-address writes: the caller can reuse that
            // address after retire returns. Query-then-replace is not atomic
            // either, so a failed initial replacement must remain quarantined.
            if (alias.fixed && !initial_retirement) continue;
            if (!alias.fixed) {
                if (!remaining_unmaps) continue;
                --remaining_unmaps;
            }
            const int result = ops.unmap(context, alias.address, alias.bytes, alias.fixed);
            if (result) {
                if (alias.fixed) {
                    alias.quarantined = true;
                    object.quarantine_error = result;
                    ++stats.quarantined_fixed_alias_count;
                }
                failure = fail(NEOSWAP_RELAY_CLEANUP, result);
                continue;
            }
            --object.aliases;
            --stats.alias_count;
            stats.mapped_alias_bytes -= alias.bytes;
            alias = {};
        }
        if (failure) return failure;
        if (object.quarantine_error) {
            // Report the original retained failure without counting another OS
            // syscall/error: this pass intentionally did not touch that range.
            stats.last_result = NEOSWAP_RELAY_CLEANUP;
            stats.last_os_error = object.quarantine_error;
            return NEOSWAP_RELAY_CLEANUP;
        }
        if (object.aliases) return fail(NEOSWAP_RELAY_BUSY);
        return finish_object(object);
    }
};

Backend::Backend(const Operations& operations, void* context) noexcept
    : state_(new (std::nothrow) State(operations, context)) {}
Backend::~Backend() {
    // Application-global instance lives until process exit. shutdown is also
    // explicit so callers can retry kernel failures before destroying a fixture.
    (void)shutdown();
}
int Backend::configure(std::uint32_t mask, std::uint64_t limit) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    if (!s.available()) return s.fail(NEOSWAP_RELAY_DISABLED);
    if ((mask & ~supported_owner_mask) || !valid_size(limit)) return s.fail(NEOSWAP_RELAY_INVALID);
    if (s.stats.object_count || s.closing) return s.fail(NEOSWAP_RELAY_BUSY);
    if (s.stats.retained_capacity_bytes > limit) return s.fail(NEOSWAP_RELAY_QUOTA);
    s.stats.enabled_owner_mask = mask;
    s.capacity_limit = limit;
    return s.success();
}
int Backend::adopt(std::uint32_t port, std::uint64_t bytes, std::int32_t pid,
                   std::uint64_t generation) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    if (!s.available() || !s.stats.enabled_owner_mask || s.closing) return s.fail(NEOSWAP_RELAY_DISABLED);
    if (!port || !valid_size(bytes) || bytes > maximum_segment_bytes || pid <= 0 || !generation)
        return s.fail(NEOSWAP_RELAY_INVALID);
    if (bytes > s.capacity_limit - s.stats.retained_capacity_bytes) return s.fail(NEOSWAP_RELAY_QUOTA);
    State::Entry* slot = nullptr;
    for (auto& entry : s.entries) {
        if (entry.port == port) return s.fail(NEOSWAP_RELAY_INVALID);
        if (!entry.port && !slot) slot = &entry;
    }
    if (!slot) return s.fail(NEOSWAP_RELAY_LIMIT);
    int result = s.ops.retain(s.context, port);
    if (result) return s.fail(NEOSWAP_RELAY_MAPPING, result);
    slot->port = port;
    slot->bytes = bytes;
    slot->pid = pid;
    slot->generation = generation;
    result = s.ops.map(s.context, port, 0, bytes, 0, NEOSWAP_RELAY_READ_WRITE, &slot->window);
    if (result || !valid_range(slot->window, bytes)) {
        // A conforming failed map has no new mapping. Retain failed cleanup
        // rights/windows for shutdown instead of claiming those bytes are free.
        const int map_error = result ? result : -1;
        const int cleanup = s.cleanup(*slot);
        s.recount_entries();
        return cleanup ? cleanup : s.fail(NEOSWAP_RELAY_MAPPING, map_error);
    }
    slot->ready = true;
    s.recount_entries();
    return s.success();
}
void Backend::set_pressure(bool raised) noexcept {
    if (!state_) return;
    std::lock_guard<std::mutex> guard(state_->mutex);
    state_->stats.pressure_raised = raised ? 1U : 0U;
}
int Backend::create(std::uint32_t owner, std::uint64_t bytes, std::uint64_t* token) noexcept {
    if (token) *token = 0;
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    if (!token || !valid_size(bytes) || owner >= 32) return s.fail(NEOSWAP_RELAY_INVALID);
    if (bytes > maximum_segment_bytes) return s.fail(NEOSWAP_RELAY_QUOTA);
    if (!(s.stats.enabled_owner_mask & (1U << owner)) || !s.stats.capacity_bytes || s.closing ||
        s.stats.quarantined_fixed_alias_count)
        return s.fail(NEOSWAP_RELAY_DISABLED);
    if (s.stats.pressure_raised || s.ops.headroom(s.context) < bytes) return s.fail(NEOSWAP_RELAY_PRESSURE);
    if (bytes > s.stats.capacity_bytes - s.stats.live_bytes) return s.fail(NEOSWAP_RELAY_QUOTA);
    if (s.next_serial > (std::numeric_limits<std::uint64_t>::max() >> token_shift))
        return s.fail(NEOSWAP_RELAY_LIMIT);
    std::size_t object_index = maximum_objects;
    for (std::size_t i = 0; i < maximum_objects; ++i) {
        const auto index = (s.next_object + i) % maximum_objects;
        if (!s.objects[index].token) { object_index = index; break; }
    }
    if (object_index == maximum_objects) return s.fail(NEOSWAP_RELAY_LIMIT);
    const std::size_t pages = bytes / alignment;
    for (std::size_t index = 0; index < s.entries.size(); ++index) {
        auto& entry = s.entries[index];
        if (!entry.ready || entry.bytes < bytes) continue;
        std::size_t contiguous = 0;
        for (std::size_t page = 0; page < entry.bytes / alignment; ++page) {
            contiguous = entry.occupied[page] ? 0 : contiguous + 1;
            if (contiguous < pages) continue;
            const auto first = page + 1 - pages;
            for (auto n = first; n <= page; ++n) entry.occupied.set(n);
            auto& object = s.objects[object_index];
            object = {(s.next_serial++ << token_shift) | object_index, bytes,
                      first * alignment, static_cast<std::uint32_t>(index), owner, 0, false, 0};
            s.next_object = (object_index + 1) % maximum_objects;
            s.stats.live_bytes += bytes;
            s.stats.peak_live_bytes = std::max(s.stats.peak_live_bytes, s.stats.live_bytes);
            ++s.stats.object_count;
            *token = object.token;
            return s.success();
        }
    }
    return s.fail(NEOSWAP_RELAY_QUOTA); // Total free capacity can be fragmented.
}
int Backend::map(std::uint64_t token, void* target, std::uint32_t protection, void** mapped) noexcept {
    if (mapped) *mapped = nullptr;
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    auto* object = s.object(token);
    if (!object) return s.fail(NEOSWAP_RELAY_UNKNOWN);
    if (object->retiring) return s.fail(NEOSWAP_RELAY_BUSY);
    const auto address = reinterpret_cast<std::uintptr_t>(target);
    if (!mapped || (protection != NEOSWAP_RELAY_NONE && protection != NEOSWAP_RELAY_READ &&
                    protection != NEOSWAP_RELAY_READ_WRITE) || (address && !valid_range(address, object->bytes)))
        return s.fail(NEOSWAP_RELAY_INVALID);
    // Existing tokens survive pressure and retain all lifetime guarantees. No
    // new aliases are published under pressure; callers can use their fallback.
    if (s.stats.pressure_raised || s.ops.headroom(s.context) < object->bytes)
        return s.fail(NEOSWAP_RELAY_PRESSURE);
    std::size_t alias_index = maximum_aliases;
    for (std::size_t i = 0; i < maximum_aliases; ++i) {
        const auto index = (s.next_alias + i) % maximum_aliases;
        const auto& alias = s.aliases[index];
        if (!alias.token && alias_index == maximum_aliases) alias_index = index;
        if (address && alias.token && overlaps(address, object->bytes, alias.address, alias.bytes))
            return s.fail(NEOSWAP_RELAY_INVALID);
    }
    if (address) for (const auto& entry : s.entries) {
        if (entry.window && overlaps(address, object->bytes, entry.window, entry.bytes))
            return s.fail(NEOSWAP_RELAY_INVALID);
    }
    if (alias_index == maximum_aliases) return s.fail(NEOSWAP_RELAY_LIMIT);
    auto& entry = s.entries[object->entry];
    std::uintptr_t destination = 0;
    const int result = s.ops.map(s.context, entry.port, object->offset, object->bytes,
                                 address, protection, &destination);
    if (result) return s.fail(NEOSWAP_RELAY_MAPPING, result);
    // Darwin guarantees aligned ANYWHERE and exact FIXED results. A mock must
    // honor the same contract; bookkeeping uses the returned live address.
    s.aliases[alias_index] = {token, object->bytes, destination, address != 0, false};
    s.next_alias = (alias_index + 1) % maximum_aliases;
    ++object->aliases;
    ++s.stats.alias_count;
    s.stats.mapped_alias_bytes += object->bytes;
    *mapped = reinterpret_cast<void*>(destination);
    return s.success();
}
int Backend::unmap(std::uint64_t token, void* address) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    auto* object = s.object(token);
    if (!object) return s.fail(NEOSWAP_RELAY_UNKNOWN);
    if (object->retiring) return s.fail(NEOSWAP_RELAY_BUSY);
    for (auto& alias : s.aliases) {
        if (alias.token != token || alias.address != reinterpret_cast<std::uintptr_t>(address)) continue;
        const int result = s.ops.unmap(s.context, alias.address, alias.bytes, alias.fixed);
        if (result) return s.fail(NEOSWAP_RELAY_MAPPING, result);
        --object->aliases;
        --s.stats.alias_count;
        s.stats.mapped_alias_bytes -= alias.bytes;
        alias = {};
        return s.success();
    }
    return s.fail(NEOSWAP_RELAY_UNKNOWN);
}
int Backend::release(std::uint64_t token) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    auto* object = s.object(token);
    if (!object) return s.fail(NEOSWAP_RELAY_UNKNOWN);
    return s.finish_object(*object);
}
int Backend::retire(std::uint64_t token) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    auto* object = s.object(token);
    if (!object) return s.fail(NEOSWAP_RELAY_UNKNOWN);
    const bool initial_retirement = !object->retiring;
    if (initial_retirement) {
        object->retiring = true;
        ++s.stats.retiring_object_count;
    }
    unsigned remaining_unmaps = 64;
    return s.collect_object(*object, remaining_unmaps, initial_retirement);
}
int Backend::collect() noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    unsigned remaining_unmaps = 64, remaining_objects = 4;
    int failure = NEOSWAP_RELAY_OK;
    int failure_os = 0;
    const auto first = s.next_collect;
    for (std::size_t i = 0; i < maximum_objects; ++i) {
        const auto index = (first + i) % maximum_objects;
        auto& object = s.objects[index];
        if (!object.token || !object.retiring) continue;
        if (!remaining_objects) break;
        --remaining_objects;
        s.next_collect = (index + 1) % maximum_objects;
        const int result = s.collect_object(object, remaining_unmaps);
        if (result) { failure = result; failure_os = s.stats.last_os_error; }
    }
    if (failure) {
        s.stats.last_result = failure;
        s.stats.last_os_error = failure_os;
        return failure;
    }
    return s.stats.retiring_object_count ? s.fail(NEOSWAP_RELAY_BUSY) : s.success();
}
int Backend::enabled(std::uint32_t owner) noexcept {
    if (!state_ || owner >= 32) return 0;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    return !s.closing && !s.stats.pressure_raised && !s.stats.quarantined_fixed_alias_count && s.stats.capacity_bytes &&
        (s.stats.enabled_owner_mask & (1U << owner)) ? 1 : 0;
}
int Backend::snapshot(NeoSwapRelayStats* output) noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    if (!output || output->struct_size < sizeof(NeoSwapRelayStats)) return s.fail(NEOSWAP_RELAY_INVALID);
    *output = s.stats;
    return NEOSWAP_RELAY_OK;
}
int Backend::shutdown() noexcept {
    if (!state_) return NEOSWAP_RELAY_DISABLED;
    auto& s = *state_;
    std::lock_guard<std::mutex> guard(s.mutex);
    if (s.stats.object_count) return s.fail(NEOSWAP_RELAY_BUSY);
    s.closing = true;
    s.stats.enabled_owner_mask = 0;
    int result = NEOSWAP_RELAY_OK;
    for (auto& entry : s.entries) if (entry.port) {
        const int current = s.cleanup(entry);
        if (current) result = current;
    }
    s.recount_entries();
    if (result) return result;
    s.closing = false;
    s.stats.pressure_raised = 0;
    return s.success();
}

namespace {
#if defined(__APPLE__)
int retain(void*, std::uint32_t entry) {
    return mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1);
}
int drop(void*, std::uint32_t entry) { return mach_port_deallocate(mach_task_self(), entry); }
int map_pages(void*, std::uint32_t entry, std::uint64_t offset, std::uint64_t bytes,
              std::uintptr_t target, std::uint32_t protection, std::uintptr_t* mapped) {
    mach_vm_address_t address = target;
    const auto result = mach_vm_map(mach_task_self(), &address, bytes,
        target ? 0 : alignment - 1, target ? VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE : VM_FLAGS_ANYWHERE,
        entry, offset, FALSE, static_cast<vm_prot_t>(protection), VM_PROT_READ | VM_PROT_WRITE,
        VM_INHERIT_NONE);
    if (result == KERN_SUCCESS) *mapped = static_cast<std::uintptr_t>(address);
    return result;
}
int unmap_pages(void*, std::uintptr_t address, std::uint64_t bytes, bool fixed) {
    if (!fixed) return mach_vm_deallocate(mach_task_self(), address, bytes);
    mach_vm_address_t destination = address;
    // One atomic replacement preserves ownership of the reserved address even
    // if another thread allocates VM regions concurrently with guest teardown.
    return mach_vm_map(mach_task_self(), &destination, bytes, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, MEMORY_OBJECT_NULL, 0, FALSE,
        VM_PROT_NONE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
}
int zero_pages(void*, std::uintptr_t address, std::uint64_t bytes) {
    if (madvise(reinterpret_cast<void*>(address), static_cast<std::size_t>(bytes), MADV_ZERO) == 0)
        return 0;
    return errno;
}
std::uint64_t headroom(void*) {
    donation::SystemHeadroom sample;
    if (!donation::system_headroom(sample)) return 0;
    if (sample.pressure == donation::MemoryPressure::warning ||
        sample.pressure == donation::MemoryPressure::critical) return 0;
    return sample.usable_bytes;
}
const Operations system_operations{retain, drop, map_pages, unmap_pages, zero_pages, headroom};
#else
const Operations system_operations{}; // No fabricated portable donation.
#endif
} // namespace
Backend& backend() noexcept { static Backend instance(system_operations); return instance; }
int configure(std::uint32_t mask, std::uint64_t limit) noexcept { return backend().configure(mask, limit); }
int adopt(std::uint32_t entry, std::uint64_t bytes, std::int32_t pid, std::uint64_t generation) noexcept {
    return backend().adopt(entry, bytes, pid, generation);
}
void set_pressure(bool raised) noexcept { backend().set_pressure(raised); }
int shutdown() noexcept { return backend().shutdown(); }
int collect() noexcept { return backend().collect(); }
} // namespace neostation::relay

extern "C" const NeoSwapRelayAPI* NeoSwap_GetRelayAPI(std::uint32_t abi) {
    static const NeoSwapRelayAPI api{sizeof(NeoSwapRelayAPI), NEOSWAP_RELAY_ABI,
        [](std::uint32_t owner, std::uint64_t bytes, std::uint64_t* token) {
            return neostation::relay::backend().create(owner, bytes, token);
        },
        [](std::uint64_t token, void* target, std::uint32_t protection, void** mapped) {
            return neostation::relay::backend().map(token, target, protection, mapped);
        },
        [](std::uint64_t token, void* address) { return neostation::relay::backend().unmap(token, address); },
        [](std::uint64_t token) { return neostation::relay::backend().release(token); },
        [](std::uint32_t owner) { return neostation::relay::backend().enabled(owner); },
        [](NeoSwapRelayStats* stats) { return neostation::relay::backend().snapshot(stats); },
        [](std::uint64_t token) { return neostation::relay::backend().retire(token); }};
    return abi == NEOSWAP_RELAY_ABI ? &api : nullptr;
}
