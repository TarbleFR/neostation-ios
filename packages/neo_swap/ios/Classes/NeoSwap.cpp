// Original NeoStation implementation. See docs/neoswap-v1.md for its scope.
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#if defined(NEOSWAP_DONATION)
#include "Donation/Pool.h"
#endif
#include <algorithm>
#include <array>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <unistd.h>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
constexpr size_t large_block_slots = 256;
constexpr size_t small_block_slots = 768;
constexpr size_t max_blocks = large_block_slots + small_block_slots;
constexpr uint64_t small_cpu_budget = 512 * MiB;
constexpr uint64_t small_cpu_minimum = 64 * 1024;
// Four diagnostic size bins: [64,128), [128,256), [256,512), [512,1024) KiB.
unsigned cpu_size_bin(uint64_t bytes) noexcept {
    return bytes < 128 * 1024 ? 0 : bytes < 256 * 1024 ? 1 : bytes < 512 * 1024 ? 2 : 3;
}
struct CPUBufferCounters {
    std::atomic<uint64_t> requests{0}, requested_bytes{0}, successful_allocations{0}, fallback_count{0};
    std::atomic<uint64_t> live_bytes{0}, peak_bytes{0}, live_blocks{0}, allocated_bytes{0};
    std::atomic<uint64_t> pressure_refusals{0}, policy_refusals{0}, pool_misses{0};
    std::array<std::atomic<uint64_t>, 4> request_bins{}, donated_bins{};
    std::atomic<bool> enabled{false}, pressure_raised{true};
};
constexpr uint64_t max_block_bytes = 8 * 1024 * MiB;
[[maybe_unused]] constexpr uint64_t max_donation_block_bytes = 256 * MiB;
struct Block {
    void* address = nullptr;
    uint64_t size = 0;
    uint32_t owner = 0;
    int fd = -1;
    uint64_t donation_token = 0;
    bool small_cpu = false;
    // A file allocation owns only this exact region. A rejected allocation
    // whose cleanup failed keeps it here, without exposing a client pointer.
    void* region = nullptr;
    uint64_t region_size = 0;
};
struct HostCounters {
    std::atomic<uint64_t> reserved_virtual_bytes{0}, disk_free_bytes{0}, remaining_storage_bytes{0};
    std::atomic<int32_t> reservation_result{NEOSWAP_OK}, reservation_errno{0};
    std::array<std::atomic<int32_t>, NEOSWAP_OWNER_COUNT> owner_last_result{}, owner_last_errno{};
    std::atomic<uint64_t> donor_pending_demand_bytes{0}, donor_inflight_demand_bytes{0};
    std::atomic<uint64_t> donor_pending_demand_count{0}, donor_demand_overflow_count{0};
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<int32_t>::is_always_lock_free);
struct Broker {
    std::mutex mutex;
    std::array<Block, max_blocks> blocks{};
    NeoSwapConfig config{};
#if defined(NEOSWAP_DONATION)
    NeoSwapConfig donation_config{};
    uint64_t demand_sequence = 0;
    NeoSwapDonationDemand inflight_demand{};
    std::array<NeoSwapDonationDemand, 64> pending_demands{};
#endif
    NeoSwapStats stats{};
    HostCounters host_stats{};
    CPUBufferCounters cpu_buffers{};
    int directory = -1;
    uint64_t next_name = 1;
    uint64_t file_live_bytes = 0, shared_live_bytes = 0;
    std::atomic<uint32_t> enabled_mask{0}, live_count{0}, active_session_mask{0};
#if defined(NEOSWAP_DONATION)
    std::atomic<uint32_t> donation_enabled_mask{0};
#endif
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_bytes{};
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_donated_bytes{};
#ifdef NEOSWAP_TESTING
    int failure = 0;
#endif
    ~Broker() {
        for (auto& b : blocks) {
            if (b.address && b.fd >= 0) ::close(b.fd);
            if (b.region) ::munmap(b.region, b.region_size);
        }
        if (directory >= 0) ::close(directory);
    }
};
Broker& broker() { static Broker b; return b; }
#if defined(NEOSWAP_DONATION)
void publish_demands(Broker& b) {
    uint64_t smallest = 0, count = 0;
    for (const auto& demand : b.pending_demands) if (demand.bytes) {
        smallest = smallest ? std::min(smallest, demand.bytes) : demand.bytes;
        ++count;
    }
    b.host_stats.donor_pending_demand_bytes.store(smallest, std::memory_order_relaxed);
    b.host_stats.donor_pending_demand_count.store(count, std::memory_order_relaxed);
    b.host_stats.donor_inflight_demand_bytes.store(b.inflight_demand.bytes, std::memory_order_relaxed);
}
void request_donation(Broker& b, uint64_t bytes) {
    // This is a failed real host-buffer request, never a memory allocation.
    // Bound hints as well as chunks. New small requests must not be hidden by
    // an older large request for which the measured headroom is insufficient.
    if (!bytes || bytes > max_donation_block_bytes || b.demand_sequence == UINT64_MAX) return;
    NeoSwapDonationDemand* free = nullptr;
    NeoSwapDonationDemand* largest = nullptr;
    for (auto& demand : b.pending_demands) {
        if (demand.bytes == bytes) {
            demand.sequence = ++b.demand_sequence;
            publish_demands(b); return;
        }
        if (!demand.bytes && !free) free = &demand;
        if (demand.bytes && (!largest || demand.bytes > largest->bytes)) largest = &demand;
    }
    if (!free) {
        b.host_stats.donor_demand_overflow_count.fetch_add(1, std::memory_order_relaxed);
        if (!largest || bytes >= largest->bytes) return;
        free = largest;
    }
    *free = {++b.demand_sequence, bytes};
    publish_demands(b);
}
#endif
[[maybe_unused]] bool donation_ready() {
#if defined(NEOSWAP_DONATION)
    neostation::donation::PoolSnapshot stats{};
    neostation::donation::pool_snapshot(stats);
    return stats.state == neostation::donation::PoolState::verified;
#else
    return false;
#endif
}
uint64_t effective_capacity(const Broker& b) {
#if defined(NEOSWAP_DONATION)
    if (b.shared_live_bytes || donation_ready())
        return std::max(b.config.capacity_bytes, b.donation_config.capacity_bytes);
#endif
    return b.config.capacity_bytes;
}
void host_snapshot(const Broker& b, NeoSwapHostStats* out) {
    // Display reads must not wait for a file reservation held under the broker
    // mutex. Cumulative diagnostic fields are independently sampled atomics.
    const auto& h = b.host_stats;
    out->reserved_virtual_bytes = h.reserved_virtual_bytes.load(std::memory_order_relaxed);
    out->disk_free_bytes = h.disk_free_bytes.load(std::memory_order_relaxed);
    out->remaining_storage_bytes = h.remaining_storage_bytes.load(std::memory_order_relaxed);
    out->reservation_result = h.reservation_result.load(std::memory_order_relaxed);
    out->reservation_errno = h.reservation_errno.load(std::memory_order_relaxed);
    for (uint32_t i = 0; i < NEOSWAP_OWNER_COUNT; ++i) {
        out->owner_last_result[i] = h.owner_last_result[i].load(std::memory_order_relaxed);
        out->owner_last_errno[i] = h.owner_last_errno[i].load(std::memory_order_relaxed);
        out->owner_donated_live_bytes[i] = b.owner_donated_bytes[i].load(std::memory_order_relaxed);
    }
    out->donated_live_bytes = out->donor_prepared_bytes = out->donor_footprint_bytes = 0;
    out->donor_nonvolatile_bytes = out->donor_compressed_bytes = out->donor_generation = 0;
    out->donor_pid = out->donation_state = out->donation_last_stage = out->donation_last_kernel_result = 0;
    out->donor_target_bytes = out->donor_retained_bytes = out->donor_retained_live_bytes = 0;
    out->donor_resident_bytes = out->donor_accounted_compressed_bytes = 0;
    out->donor_count = out->donor_lost_count = 0;
    out->file_ready_owner_mask = b.enabled_mask.load(std::memory_order_acquire);
    out->donor_pending_demand_bytes = h.donor_pending_demand_bytes.load(std::memory_order_relaxed);
    out->donor_inflight_demand_bytes = h.donor_inflight_demand_bytes.load(std::memory_order_relaxed);
    out->donor_pending_demand_count = h.donor_pending_demand_count.load(std::memory_order_relaxed);
    out->donor_demand_overflow_count = h.donor_demand_overflow_count.load(std::memory_order_relaxed);
#if defined(NEOSWAP_DONATION)
    neostation::donation::PoolSnapshot donation{};
    neostation::donation::pool_snapshot(donation);
    out->donated_live_bytes = donation.live_bytes;
    out->donor_prepared_bytes = donation.prepared_bytes;
    out->donor_footprint_bytes = donation.donor_footprint;
    out->donor_nonvolatile_bytes = donation.donor_nonvolatile;
    out->donor_compressed_bytes = donation.donor_nonvolatile_compressed;
    out->donor_generation = donation.generation;
    out->donor_pid = donation.donor_pid;
    out->donation_state = static_cast<int32_t>(donation.state);
    out->donation_last_stage = static_cast<int32_t>(donation.last_stage);
    out->donation_last_kernel_result = donation.last_kernel_result;
    out->donor_target_bytes = donation.target_bytes;
    out->donor_retained_bytes = donation.retained_bytes;
    out->donor_retained_live_bytes = donation.retained_live_bytes;
    out->donor_resident_bytes = donation.resident_bytes;
    out->donor_accounted_compressed_bytes = donation.compressed_bytes;
    out->donor_count = donation.donor_count;
    out->donor_lost_count = donation.lost_donor_count;
#endif
}
bool fail(Broker& b, int stage) {
#ifdef NEOSWAP_TESTING
    if (b.failure == stage) { b.failure = 0; errno = EIO; return true; }
#else
    (void)b; (void)stage;
#endif
    return false;
}
bool power_of_two(uint64_t n) { return n && !(n & (n - 1)); }
int reject(Broker& b, uint32_t owner, int result, int error = 0) {
    ++b.stats.rejection_count;
    if (owner < NEOSWAP_OWNER_COUNT) {
        ++b.stats.owners[owner].rejection_count;
        b.host_stats.owner_last_result[owner] = result;
        b.host_stats.owner_last_errno[owner] = error;
    }
    b.stats.last_result = result; b.stats.last_errno = error;
    if (result == NEOSWAP_IO || result == NEOSWAP_MAPPING) ++b.stats.io_errors;
    return result;
}
int preallocate(int fd, uint64_t bytes) {
#ifdef __APPLE__
    fstore_t store{};
    store.fst_flags = F_ALLOCATEALL;
    store.fst_posmode = F_PEOFPOSMODE;
    store.fst_length = static_cast<off_t>(bytes);
    int ret;
    do { ret = ::fcntl(fd, F_PREALLOCATE, &store); } while (ret < 0 && errno == EINTR);
    if (ret < 0) return -1;
#else
    int ret;
    do { ret = ::posix_fallocate(fd, 0, static_cast<off_t>(bytes)); } while (ret == EINTR);
    if (ret) { errno = ret; return -1; }
#endif
    // Never map a sparse promise and hope that space will exist on first write.
    return ::ftruncate(fd, static_cast<off_t>(bytes));
}
void reservation_error(Broker& b, int error) {
    b.host_stats.reservation_result = NEOSWAP_MAPPING;
    b.host_stats.reservation_errno = error;
}
int discard_region(Broker& b, Block& block, bool injected_failure = false) {
    if (!block.region) return 0;
    if (injected_failure || ::munmap(block.region, block.region_size)) {
        if (injected_failure) errno = EIO;
        reservation_error(b, errno);
        return -1; // keep the complete owned interval for a later retry
    }
    b.host_stats.reserved_virtual_bytes.fetch_sub(block.region_size, std::memory_order_relaxed);
    block.region = nullptr;
    block.region_size = 0;
    return 0;
}
int cleanup_rejected_regions(Broker& b) {
    int error = 0;
    for (auto& block : b.blocks) if (!block.address && block.region) {
        // Fault 8 exercises a rejected region's retry, independently of the
        // original mapping/cleanup failure (fault 7).
        if (discard_region(b, block, fail(b, 8)) && !error) error = errno;
    }
    if (error) { errno = error; return -1; }
    return 0;
}
void* reserve_region(Broker& b, Block& block, size_t bytes, size_t alignment, size_t page) {
    // Reserve only this work buffer. Alignment padding exists briefly while
    // trimming and is never retained on a successful allocation. Bookkeeping
    // starts before any fallible trim so rejected cleanup cannot lose ownership.
    const size_t span = bytes + (alignment > page ? alignment - page : 0);
    void* original = fail(b, 6) ? MAP_FAILED : ::mmap(nullptr, span,
        PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (original == MAP_FAILED) { reservation_error(b, errno); return MAP_FAILED; }
    block.region = original;
    block.region_size = span;
    b.host_stats.reserved_virtual_bytes.fetch_add(span, std::memory_order_relaxed);
    const uintptr_t start = reinterpret_cast<uintptr_t>(original);
    const uintptr_t aligned = (start + alignment - 1) & ~(alignment - 1);
    const size_t prefix = aligned - start;
    const size_t suffix = span - prefix - bytes;
    if (prefix) {
        if (::munmap(original, prefix)) {
            const int error = errno;
            discard_region(b, block);
            reservation_error(b, error); errno = error;
            return MAP_FAILED;
        }
        block.region = reinterpret_cast<void*>(aligned);
        block.region_size -= prefix;
        b.host_stats.reserved_virtual_bytes.fetch_sub(prefix, std::memory_order_relaxed);
    }
    if (suffix) {
        if (::munmap(reinterpret_cast<void*>(aligned + bytes), suffix)) {
            const int error = errno;
            discard_region(b, block);
            reservation_error(b, error); errno = error;
            return MAP_FAILED;
        }
        block.region_size -= suffix;
        b.host_stats.reserved_virtual_bytes.fetch_sub(suffix, std::memory_order_relaxed);
    }
    b.host_stats.reservation_result = NEOSWAP_OK;
    b.host_stats.reservation_errno = 0;
    return block.region;
}
int record_allocation(Broker& b, Block& slot, void* address, uint64_t size,
                      uint32_t owner, int fd, uint64_t donation_token,
                      std::chrono::steady_clock::time_point started, void** out) {
    // Preserve the file region acquired before MAP_FIXED; a donor has none.
    slot.address = address; slot.size = size; slot.owner = owner;
    slot.fd = fd; slot.donation_token = donation_token;
    if (donation_token) {
        b.shared_live_bytes += size;
        b.owner_donated_bytes[owner].fetch_add(size, std::memory_order_relaxed);
    }
    else b.file_live_bytes += size;
    b.stats.live_bytes += size; ++b.stats.live_blocks; ++b.stats.allocation_count;
    if (b.stats.live_bytes > b.stats.peak_bytes) b.stats.peak_bytes = b.stats.live_bytes;
    auto& o = b.stats.owners[owner]; o.live_bytes += size; ++o.allocation_count;
    if (o.live_bytes > o.peak_bytes) o.peak_bytes = o.live_bytes;
    b.owner_bytes[owner].store(o.live_bytes, std::memory_order_relaxed);
    const auto elapsed = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count());
    b.stats.allocation_time_us += elapsed;
    if (elapsed > b.stats.max_allocation_time_us) b.stats.max_allocation_time_us = elapsed;
    b.live_count.store(static_cast<uint32_t>(b.stats.live_blocks), std::memory_order_release);
    b.host_stats.owner_last_result[owner] = NEOSWAP_OK;
    b.host_stats.owner_last_errno[owner] = 0;
    *out = address;
    return NEOSWAP_OK;
}
int allocate(uint32_t owner, uint32_t kind, uint64_t bytes, uint64_t alignment, void** out) {
    if (!out) return NEOSWAP_INVALID;
    *out = nullptr;
    // Legacy ABI slots are reserved, never eligible clients. Refuse before
    // broker locks, file creation, donor demand or allocation accounting.
    if (owner >= NEOSWAP_OWNER_COUNT) return NEOSWAP_INVALID;
    if (owner != NEOSWAP_RPCS3) return NEOSWAP_DISABLED;
    auto& b = broker();
    const bool small_cpu = owner == NEOSWAP_RPCS3 && kind == NEOSWAP_CPU_CACHE &&
        bytes >= small_cpu_minimum && bytes < MiB;
    if (small_cpu && (!power_of_two(alignment) || alignment > 65536))
        return NEOSWAP_INVALID;
    auto& cpu = b.cpu_buffers;
    // Title-disabled requests must not add a mutex/file/extension wait to the
    // old heap path. Validate the public API before accepting any borrowed data.
    if (small_cpu) {
        cpu.requests.fetch_add(1, std::memory_order_relaxed);
        cpu.requested_bytes.fetch_add(bytes, std::memory_order_relaxed);
        cpu.request_bins[cpu_size_bin(bytes)].fetch_add(1, std::memory_order_relaxed);
        if (!cpu.enabled.load(std::memory_order_acquire) || cpu.pressure_raised.load(std::memory_order_acquire)) {
            cpu.fallback_count.fetch_add(1, std::memory_order_relaxed);
            if (cpu.pressure_raised.load(std::memory_order_relaxed))
                cpu.pressure_refusals.fetch_add(1, std::memory_order_relaxed);
            else cpu.policy_refusals.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_DISABLED;
        }
    }
    // One accounting path includes every refusal, not only absent donors.
    struct CPUAttempt {
        CPUBufferCounters* counters;
        bool success = false;
        ~CPUAttempt() { if (counters && !success) counters->fallback_count.fetch_add(1, std::memory_order_relaxed); }
    } attempt{small_cpu ? &cpu : nullptr};
    std::lock_guard guard(b.mutex);
    if (owner >= NEOSWAP_OWNER_COUNT || (kind != NEOSWAP_CPU_DATA && kind != NEOSWAP_CPU_CACHE) ||
        !bytes || !power_of_two(alignment) || alignment > 65536 || bytes > max_block_bytes)
        return reject(b, owner, NEOSWAP_INVALID);
    bool donor_enabled = false;
#if defined(NEOSWAP_DONATION)
    donor_enabled = owner == NEOSWAP_RPCS3 && b.donation_config.capacity_bytes &&
        (b.donation_config.enabled_owner_mask & (1u << owner)) && donation_ready();
#endif
    const bool file_enabled = b.config.capacity_bytes && b.directory >= 0 &&
        (b.config.enabled_owner_mask & (1u << owner));
    if (!file_enabled && !donor_enabled)
        return reject(b, owner, NEOSWAP_DISABLED);
    uint64_t minimum = b.config.minimum_allocation_bytes;
#if defined(NEOSWAP_DONATION)
    if (donor_enabled) minimum = b.donation_config.minimum_allocation_bytes;
#endif
    if (small_cpu) {
        // Small CPU data borrows verified RAM only; never create hundreds of
        // small swap files or consume the 256 legacy large-allocation slots.
        if (!cpu.enabled.load(std::memory_order_acquire) || cpu.pressure_raised.load(std::memory_order_acquire)) {
            cpu.pressure_refusals.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_DISABLED;
        }
        minimum = small_cpu_minimum;
    }
    if (bytes < minimum) return reject(b, owner, NEOSWAP_TOO_SMALL);
    const long page_long = ::sysconf(_SC_PAGESIZE);
    if (page_long <= 0 || !power_of_two(static_cast<uint64_t>(page_long)))
        return reject(b, owner, NEOSWAP_MAPPING, EINVAL);
    const auto page = static_cast<uint64_t>(page_long);
    const uint64_t rounded = (bytes + page - 1) & ~(page - 1);
    const auto capacity = effective_capacity(b);
    if (b.stats.live_bytes > capacity || rounded > capacity - b.stats.live_bytes)
        return reject(b, owner, NEOSWAP_QUOTA);
    Block* slot = nullptr;
    if (small_cpu && (cpu.live_bytes.load(std::memory_order_relaxed) > small_cpu_budget ||
        rounded > small_cpu_budget - cpu.live_bytes.load(std::memory_order_relaxed))) {
        cpu.policy_refusals.fetch_add(1, std::memory_order_relaxed);
        return reject(b, owner, NEOSWAP_QUOTA);
    }
    const size_t first_slot = small_cpu ? large_block_slots : 0;
    const size_t last_slot = small_cpu ? max_blocks : large_block_slots;
    for (size_t i = first_slot; i < last_slot; ++i) {
        auto& item = b.blocks[i];
        if (!item.address && !item.region) { slot = &item; break; }
    }
    if (!slot || b.next_name == std::numeric_limits<uint64_t>::max()) return reject(b, owner, NEOSWAP_LIMIT);
    const auto started = std::chrono::steady_clock::now();
#if defined(NEOSWAP_DONATION)
    // Borrow only a verified helper-owned object, entirely locally. Never wait
    // for extension launch/XPC on an RPCS3 thread.
    if (donor_enabled) {
        void* donated = nullptr;
        uint64_t token = 0;
        const auto acquired = neostation::donation::pool_acquire(rounded, std::max(alignment, page), &donated, &token);
        if (acquired) {
            if (small_cpu) {
                slot->small_cpu = true;
                const uint64_t live = cpu.live_bytes.fetch_add(rounded, std::memory_order_relaxed) + rounded;
                cpu.peak_bytes.store(std::max(live, cpu.peak_bytes.load(std::memory_order_relaxed)), std::memory_order_relaxed);
                cpu.live_blocks.fetch_add(1, std::memory_order_relaxed);
                cpu.allocated_bytes.fetch_add(rounded, std::memory_order_relaxed);
                cpu.successful_allocations.fetch_add(1, std::memory_order_relaxed);
                cpu.donated_bins[cpu_size_bin(bytes)].fetch_add(1, std::memory_order_relaxed);
                attempt.success = true;
            }
            return record_allocation(b, *slot, donated, rounded, owner, -1, token, started, out);
        }
        if (small_cpu) cpu.pool_misses.fetch_add(1, std::memory_order_relaxed);
        if (acquired.stage == neostation::donation::Stage::pool_quota ||
            acquired.stage == neostation::donation::Stage::pool_unready)
            request_donation(b, small_cpu ? std::max<uint64_t>(MiB, rounded) : rounded);
    } else if (owner == NEOSWAP_RPCS3 && b.donation_config.capacity_bytes &&
        (b.donation_config.enabled_owner_mask & (1u << owner)) &&
        (small_cpu || rounded >= b.donation_config.minimum_allocation_bytes)) {
        request_donation(b, small_cpu ? std::max<uint64_t>(MiB, rounded) : rounded); // first request may precede helper proof
    }
#endif
    if (small_cpu) return reject(b, owner, NEOSWAP_DISABLED); // no disk fallback for sub-MiB CPU requests
    if (!file_enabled) return reject(b, owner, NEOSWAP_DISABLED);
    if (cleanup_rejected_regions(b)) return reject(b, owner, NEOSWAP_MAPPING, errno);
    if (b.file_live_bytes > b.config.capacity_bytes || rounded > b.config.capacity_bytes - b.file_live_bytes)
        return reject(b, owner, NEOSWAP_QUOTA);
    struct statvfs space{};
    if (::fstatvfs(b.directory, &space) || !space.f_frsize) return reject(b, owner, NEOSWAP_STORAGE, errno);
    const uint64_t free_bytes = space.f_bavail > UINT64_MAX / space.f_frsize
        ? UINT64_MAX : static_cast<uint64_t>(space.f_bavail) * space.f_frsize;
    b.host_stats.disk_free_bytes = free_bytes;
    b.host_stats.remaining_storage_bytes = std::min<uint64_t>(
        free_bytes > b.config.minimum_free_bytes ? free_bytes - b.config.minimum_free_bytes : 0,
        b.config.capacity_bytes - b.file_live_bytes);
    if (free_bytes < rounded || free_bytes - rounded < b.config.minimum_free_bytes)
        return reject(b, owner, NEOSWAP_STORAGE, ENOSPC);
    char name[80];
    std::snprintf(name, sizeof(name), "neoswap-%ld-%llu.tmp", static_cast<long>(::getpid()),
                  static_cast<unsigned long long>(b.next_name++));
    int fd = fail(b, 1) ? -1 : ::openat(b.directory, name,
        O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return reject(b, owner, NEOSWAP_IO, errno);
    // From now on no directory purge or stale filename can truncate this file.
    // Process death closes the descriptor and frees its storage automatically.
    if (::unlinkat(b.directory, name, 0)) {
        const int e = errno; ::close(fd); return reject(b, owner, NEOSWAP_IO, e);
    }
    if (fail(b, 2) || preallocate(fd, rounded)) {
        const int e = errno; ::close(fd); return reject(b, owner, NEOSWAP_IO, e);
    }
    void* reserved = reserve_region(b, *slot, rounded, std::max(alignment, page), page);
    if (reserved == MAP_FAILED) {
        const int e = errno; ::close(fd); return reject(b, owner, NEOSWAP_MAPPING, e);
    }
    // MAP_FIXED replaces only this exact, continuously owned PROT_NONE region.
    // Fault 7 tests rejected mapping plus failed cleanup, without a fake client.
    const bool cleanup_failure = fail(b, 7);
    void* p = cleanup_failure || fail(b, 3) ? MAP_FAILED : ::mmap(reserved, rounded,
        PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    if (p == MAP_FAILED) {
        const int e = errno; discard_region(b, *slot, cleanup_failure);
        ::close(fd); return reject(b, owner, NEOSWAP_MAPPING, e);
    }
    return record_allocation(b, *slot, p, rounded, owner, fd, 0, started, out);
}
int release(void* p) {
    if (!p) return NEOSWAP_NOT_OWNED;
    auto& b = broker();
    if (!b.live_count.load(std::memory_order_acquire)) return NEOSWAP_NOT_OWNED;
    std::lock_guard guard(b.mutex);
    for (auto& block : b.blocks) if (block.address == p) {
#if defined(NEOSWAP_DONATION)
        if (block.donation_token) {
            auto result = neostation::donation::pool_release(block.donation_token);
            if (!result) {
                ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
                b.stats.last_errno = result.kernel_result;
                return NEOSWAP_MAPPING; // preserve ownership; do not heap-free it
            }
        } else
#endif
        {
        // Release only our recorded interval. A failed unmap retains the live
        // pointer and file; a successful release never remaps that address.
        if (fail(b, 4) || discard_region(b, block)) {
            reservation_error(b, errno);
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
            b.stats.last_errno = errno; return NEOSWAP_MAPPING; // retain descriptor/ownership
        }
        }
        const int fd = block.fd;
        if (block.small_cpu) {
            b.cpu_buffers.live_bytes.fetch_sub(block.size, std::memory_order_relaxed);
            b.cpu_buffers.live_blocks.fetch_sub(1, std::memory_order_relaxed);
        }
        if (block.donation_token) {
            b.shared_live_bytes -= block.size;
            b.owner_donated_bytes[block.owner].fetch_sub(block.size, std::memory_order_relaxed);
        }
        else b.file_live_bytes -= block.size;
        b.stats.live_bytes -= block.size; --b.stats.live_blocks;
        b.stats.owners[block.owner].live_bytes -= block.size;
        b.owner_bytes[block.owner].store(b.stats.owners[block.owner].live_bytes, std::memory_order_relaxed);
        block = Block{};
        b.live_count.store(static_cast<uint32_t>(b.stats.live_blocks), std::memory_order_release);
        // No retry of close(): its descriptor may already have been recycled.
        if (fd >= 0 && ::close(fd)) { ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno; }
        return NEOSWAP_OK;
    }
    return NEOSWAP_NOT_OWNED;
}
int sync(void* p) {
    auto& b = broker(); std::lock_guard guard(b.mutex);
    for (const auto& block : b.blocks) if (p && block.address == p) {
        if (block.donation_token) {
            std::atomic_thread_fence(std::memory_order_seq_cst);
            return NEOSWAP_OK; // shared RAM has no backing file to flush
        }
        if (fail(b, 5) || ::msync(p, block.size, MS_SYNC)) {
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno;
            return NEOSWAP_IO;
        }
        return NEOSWAP_OK;
    }
    return NEOSWAP_NOT_OWNED;
}
int enabled(uint32_t owner) {
    if (owner != NEOSWAP_RPCS3) return 0;
    auto& b = broker();
    if (b.enabled_mask.load(std::memory_order_acquire) & (1u << owner)) return 1;
#if defined(NEOSWAP_DONATION)
    // Do not make a verified donor depend on a successful file-cache policy.
    if (owner == NEOSWAP_RPCS3 && donation_ready()) {
        return (b.donation_enabled_mask.load(std::memory_order_acquire) & (1u << owner)) != 0;
    }
#endif
    return 0;
}
const NeoSwapAPI api{sizeof(NeoSwapAPI), NEOSWAP_ABI, allocate, release, sync, enabled};
}
extern "C" const NeoSwapAPI* NeoSwap_GetAPI(uint32_t version) {
    return version == NEOSWAP_ABI ? &api : nullptr;
}
extern "C" int NeoSwap_Configure(const char* path, const NeoSwapConfig* c) {
    if (!c || c->struct_size != sizeof(*c) || c->abi_version != NEOSWAP_ABI || c->reserved ||
        c->capacity_bytes > 8 * 1024 * MiB || !c->minimum_allocation_bytes ||
        c->minimum_allocation_bytes > max_block_bytes || (c->enabled_owner_mask & ~(1u << NEOSWAP_RPCS3)))
        return NEOSWAP_INVALID;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    if (b.stats.live_blocks) return NEOSWAP_BUSY;
    if (c->capacity_bytes && (!path || path[0] != '/')) return NEOSWAP_INVALID;
#if defined(NEOSWAP_DONATION)
    // This validated donor policy is independent from disk availability and
    // per-buffer mapping. A failed file reconfiguration preserves its old
    // working config while a ready donor can still serve the requested budget.
    b.donation_config = *c;
    b.donation_enabled_mask.store(c->capacity_bytes ? c->enabled_owner_mask : 0u,
                                 std::memory_order_release);
#endif
    int directory = -1;
    if (c->capacity_bytes) {
        directory = ::open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (directory < 0) return NEOSWAP_STORAGE;
        struct stat st{};
        if (::fstat(directory, &st) || !S_ISDIR(st.st_mode)) { ::close(directory); return NEOSWAP_STORAGE; }
    }
    // Configure only policy and the directory. There is no capacity-sized
    // reservation. A failed cleanup retains quarantined owned regions and
    // the previous working file policy, without erasing their diagnostics.
    if (cleanup_rejected_regions(b)) {
        const int error = errno;
        if (directory >= 0) ::close(directory);
        reservation_error(b, error);
        return NEOSWAP_MAPPING;
    }
    if (b.directory >= 0) ::close(b.directory);
    b.host_stats.reservation_result = NEOSWAP_OK;
    b.host_stats.reservation_errno = 0;
    b.directory = directory; b.config = *c;
    // Preserve cumulative evidence, including failed attempts; never reset live blocks.
    b.stats.capacity_bytes = c->capacity_bytes;
    b.stats.minimum_free_bytes = c->minimum_free_bytes;
    b.stats.enabled_owner_mask = c->enabled_owner_mask;
    b.enabled_mask.store(c->capacity_bytes ? c->enabled_owner_mask : 0u, std::memory_order_release);
    return NEOSWAP_OK;
}
extern "C" int NeoSwap_Snapshot(NeoSwapStats* out) {
    if (!out || out->struct_size != sizeof(*out)) return NEOSWAP_INVALID;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    *out = b.stats; out->struct_size = sizeof(*out); out->abi_version = NEOSWAP_ABI;
    out->capacity_bytes = effective_capacity(b);
    out->allocated_disk_bytes = 0;
    for (const auto& block : b.blocks) if (block.address && block.fd >= 0) {
        struct stat st{};
        if (::fstat(block.fd, &st) == 0 && st.st_blocks > 0)
            out->allocated_disk_bytes += static_cast<uint64_t>(st.st_blocks) * 512;
    }
    return NEOSWAP_OK;
}
extern "C" void NeoSwap_RegisterClient(uint32_t owner) {
    if (owner != NEOSWAP_RPCS3) return;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    b.stats.registered_owner_mask |= 1u << owner;
}
extern "C" int NeoSwap_SetOwnerSessionActive(uint32_t owner, int active) {
    if (owner >= NEOSWAP_OWNER_COUNT) return NEOSWAP_INVALID;
    if (owner != NEOSWAP_RPCS3) return NEOSWAP_DISABLED;
    auto& b = broker();
    const uint32_t bit = 1u << owner;
    if (active) {
        b.active_session_mask.fetch_or(bit, std::memory_order_release);
        return NEOSWAP_OK;
    }
    b.active_session_mask.fetch_and(static_cast<uint32_t>(~bit), std::memory_order_release);
    if (owner == NEOSWAP_RPCS3) b.cpu_buffers.enabled.store(false, std::memory_order_release);
#if defined(NEOSWAP_DONATION)
    if (owner == NEOSWAP_RPCS3) {
        std::lock_guard guard(b.mutex);
        b.inflight_demand = {};
        for (auto& queued : b.pending_demands) queued = {};
        publish_demands(b);
    }
#endif
    return NEOSWAP_OK;
}
extern "C" int NeoSwap_OwnerSessionActive(uint32_t owner) {
    if (owner != NEOSWAP_RPCS3) return 0;
    return (broker().active_session_mask.load(std::memory_order_acquire) & (1u << owner)) ? 1 : 0;
}
extern "C" int NeoSwap_WaitForDonationReady(uint64_t minimum_bytes, uint32_t timeout_ms) {
#if defined(NEOSWAP_DONATION)
    if (!minimum_bytes || minimum_bytes > 8ULL * 1024 * MiB) return NEOSWAP_INVALID;
    if (!NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return NEOSWAP_DISABLED;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(timeout_ms);
    for (;;) {
        neostation::donation::PoolSnapshot pool{};
        neostation::donation::pool_snapshot(pool);
        if (pool.state == neostation::donation::PoolState::verified &&
            pool.prepared_bytes >= minimum_bytes) return NEOSWAP_OK;
        if (!NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return NEOSWAP_DISABLED;
        if (!timeout_ms || std::chrono::steady_clock::now() >= deadline) return NEOSWAP_BUSY;
        ::usleep(20 * 1000);
    }
#else
    (void)minimum_bytes; (void)timeout_ms; return NEOSWAP_DISABLED;
#endif
}
extern "C" int NeoSwap_ClaimDonationDemand(NeoSwapDonationDemand* out) {
    if (!out) return NEOSWAP_INVALID;
    *out = {};
#if defined(NEOSWAP_DONATION)
    auto& b = broker(); std::lock_guard guard(b.mutex);
    NeoSwapDonationDemand* smallest = nullptr;
    for (auto& demand : b.pending_demands) if (demand.bytes &&
        (!smallest || demand.bytes < smallest->bytes)) smallest = &demand;
    if (smallest && (!b.inflight_demand.bytes || smallest->bytes < b.inflight_demand.bytes)) {
        std::swap(b.inflight_demand, *smallest);
        for (auto& queued : b.pending_demands) if (&queued != smallest && smallest->bytes &&
            queued.bytes == smallest->bytes) {
            smallest->sequence = std::max(smallest->sequence, queued.sequence);
            queued = {};
        }
    }
    *out = b.inflight_demand;
    publish_demands(b);
#endif
    return NEOSWAP_OK;
}
extern "C" int NeoSwap_AcknowledgeDonationDemand(uint64_t sequence) {
#if defined(NEOSWAP_DONATION)
    auto& b = broker(); std::lock_guard guard(b.mutex);
    if (!sequence || sequence != b.inflight_demand.sequence) return NEOSWAP_NOT_OWNED;
    b.inflight_demand = {};
    publish_demands(b);
    return NEOSWAP_OK;
#else
    (void)sequence; return NEOSWAP_NOT_OWNED;
#endif
}
extern "C" int NeoSwap_HostSnapshot(NeoSwapHostStats* out) {
    if (!out) return NEOSWAP_INVALID;
    host_snapshot(broker(), out);
    return NEOSWAP_OK;
}
extern "C" int NeoSwap_StorageSnapshot(NeoSwapHostStats* out) {
    if (!out) return NEOSWAP_INVALID;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    host_snapshot(b, out);
    out->disk_free_bytes = 0;
    out->remaining_storage_bytes = 0;
    struct statvfs space{};
    if (b.directory >= 0 && ::fstatvfs(b.directory, &space) == 0 && space.f_frsize) {
        out->disk_free_bytes = space.f_bavail > UINT64_MAX / space.f_frsize
            ? UINT64_MAX : static_cast<uint64_t>(space.f_bavail) * space.f_frsize;
        const auto usable = out->disk_free_bytes > b.config.minimum_free_bytes
            ? out->disk_free_bytes - b.config.minimum_free_bytes : 0;
        out->remaining_storage_bytes = std::min<uint64_t>(usable,
            b.config.capacity_bytes - b.file_live_bytes);
    }
    b.host_stats.disk_free_bytes = out->disk_free_bytes;
    b.host_stats.remaining_storage_bytes = out->remaining_storage_bytes;
    return NEOSWAP_OK;
}
extern "C" uint64_t NeoSwap_LiveBytes(uint32_t owner) {
    return owner < NEOSWAP_OWNER_COUNT ? broker().owner_bytes[owner].load(std::memory_order_relaxed) : 0;
}
#ifdef NEOSWAP_TESTING
extern "C" void NeoSwap_TestFailNext(int stage) {
    auto& b = broker(); std::lock_guard guard(b.mutex); b.failure = stage;
}
extern "C" int NeoSwap_TestVerifyFile(void* p, const void* expected, size_t bytes) {
    auto& b = broker(); std::lock_guard guard(b.mutex);
    for (const auto& block : b.blocks) if (p && block.address == p && bytes <= block.size) {
        std::array<unsigned char, 4096> buffer{};
        for (size_t off = 0; off < bytes;) {
            const size_t n = bytes - off < buffer.size() ? bytes - off : buffer.size();
            if (::pread(block.fd, buffer.data(), n, off) != static_cast<ssize_t>(n) ||
                std::memcmp(buffer.data(), static_cast<const unsigned char*>(expected) + off, n)) return 0;
            off += n;
        }
        return 1;
    }
    return 0;
}
#endif

extern "C" void NeoSwap_SetCPUBufferExperiment(int enabled) {
    broker().cpu_buffers.enabled.store(enabled != 0, std::memory_order_release);
}
extern "C" void NeoSwap_SetCPUBufferPressure(int raised) {
    broker().cpu_buffers.pressure_raised.store(raised != 0, std::memory_order_release);
}
extern "C" int NeoSwap_CPUBufferSnapshot(NeoSwapCPUBufferStats* output) {
    if (!output) return NEOSWAP_INVALID;
    const auto& c = broker().cpu_buffers;
#define COPY_CPU_FIELD(name) output->name = c.name.load(std::memory_order_relaxed)
    COPY_CPU_FIELD(requests); COPY_CPU_FIELD(requested_bytes);
    COPY_CPU_FIELD(successful_allocations); COPY_CPU_FIELD(fallback_count);
    COPY_CPU_FIELD(live_bytes); COPY_CPU_FIELD(peak_bytes); COPY_CPU_FIELD(live_blocks);
    COPY_CPU_FIELD(allocated_bytes); COPY_CPU_FIELD(pressure_refusals);
    COPY_CPU_FIELD(policy_refusals); COPY_CPU_FIELD(pool_misses);
    COPY_CPU_FIELD(enabled); COPY_CPU_FIELD(pressure_raised);
#undef COPY_CPU_FIELD
    for (size_t i = 0; i < 4; ++i) {
        output->request_bins[i] = c.request_bins[i].load(std::memory_order_relaxed);
        output->donated_bins[i] = c.donated_bins[i].load(std::memory_order_relaxed);
    }
    return NEOSWAP_OK;
}
