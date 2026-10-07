// Original NeoStation implementation. See docs/neoswap-v1.md for its scope.
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#if defined(NEOSWAP_DONATION)
#include "Donation/Pool.h"
#endif
#if defined(NEOSWAP_RELAY)
#include "NeoSwapRelay.h"
#endif
#include <algorithm>
#include <atomic>
#include <cstring>
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>

// Global memory manager for 7GB allocation
static std::atomic<uint64_t> g_allocated_memory{0};
static std::atomic<uint64_t> g_max_allocatable_memory{0};
static std::atomic<bool> g_initialized{false};

// Memory pool tracking
struct NeoSwapMemoryBlock {
    void* address;
    size_t size;
    bool is_cached;
    int priority;
    
    NeoSwapMemoryBlock() : address(nullptr), size(0), is_cached(false), priority(0) {}
};

// Static memory pool for tracking allocations
static std::vector<NeoSwapMemoryBlock> g_memory_pool;

// Define missing types and constants
typedef enum {
    NEOSWAP_SUCCESS = 0,
    NEOSWAP_ERROR_NOT_INITIALIZED = -1,
    NEOSWAP_ERROR_INVALID_ARGUMENT = -2,
    NEOSWAP_ERROR_UNKNOWN = -3
} NeoSwapError;

typedef enum {
    NEOSWAP_FLAG_NONE = 0,
    NEOSWAP_FLAG_NO_CACHE = 1,
    NEOSWAP_FLAG_HIGH_PRIORITY = 2
} NeoSwapFlags;

extern "C" {
// Static memory pool for tracking allocations
static std::vector<NeoSwapMemoryBlock> g_memory_pool;

extern "C" {

// Initialize the NeoSwap system with 7GB target allocation
NeoSwapError NeoSwapInitialize() {
    if (g_initialized.load()) {
        return NEOSWAP_SUCCESS;
    }
    // Use vm_allocate for iOS memory management (mach_vm functions not available in all iOS versions)
    vm_address_t address = 0;
    kern_return_t kr = vm_allocate(mach_task_self(), &address, size, VM_FLAGS_ANYWHERE);
    
    if (kr != KERN_SUCCESS) {
        return nullptr;
    }
    
    // Check if we can allocate this amount
    if (size > g_max_allocatable_memory.load() - g_allocated_memory.load()) {
        return nullptr;
    }
    
    // Use mach_vm_allocate for better iOS memory management
    vm_address_t address = 0;
    // Apply flags to avoid jetsam and improve performance
    if (flags & NEOSWAP_FLAG_NO_CACHE) {
        // For iOS, we use vm_attributes_set instead of mach_vm_attributes_set
        kr = vm_attributes_set(mach_task_self(), address, size, VM_ATTRIBUTE_NO_CACHE);
        if (kr != KERN_SUCCESS) {
            // Log but continue - not critical for allocation
            NSLog(@"Failed to set no-cache attribute: %d", kr);
        }
    }
    
    if (flags & NEOSWAP_FLAG_HIGH_PRIORITY) {
        // For iOS, we use vm_set_memory_priority instead of mach_vm_set_memory_priority
        kr = vm_set_memory_priority(mach_task_self(), address, size, VM_MEMORY_PRIORITY_HIGH);
        if (kr != KERN_SUCCESS) {
            // Log but continue - not critical for allocation
            NSLog(@"Failed to set memory priority: %d", kr);
        }
    }
    }
    
    // Track the allocation
    NeoSwapMemoryBlock block;
    block.address = (void*)address;
    block.size = size;
    block.is_cached = !(flags & NEOSWAP_FLAG_NO_CACHE);
    block.priority = (flags & NEOSWAP_FLAG_HIGH_PRIORITY) ? 1 : 0;
    
    g_memory_pool.push_back(block);
    g_allocated_memory += size;
    
    // Deallocate using vm_deallocate
    kern_return_t kr = vm_deallocate(mach_task_self(), (vm_address_t)ptr, it->size);
                g_memory_pool.erase(it);
                return;
            }
        }
    }
}

// Get current memory statistics
NeoSwapStats NeoSwapGetStats() {
    NeoSwapStats stats = {};
    stats.total_memory = NSProcessInfo.processInfo.physicalMemory;
    stats.allocated_memory = g_allocated_memory.load();
    stats.max_allocatable_memory = g_max_allocatable_memory.load();
// Get current memory statistics
NeoSwapStats NeoSwapGetStats() {
    NeoSwapStats stats = {};
    
    // For iOS, we need to use sysconf to get physical memory
    long pages = sysconf(_SC_PHYS_PAGES);
    long page_size = sysconf(_SC_PAGE_SIZE);
    stats.total_memory = (uint64_t)pages * (uint64_t)page_size;
    
    stats.allocated_memory = g_allocated_memory.load();
    stats.max_allocatable_memory = g_max_allocatable_memory.load();
    stats.available_memory = g_max_allocatable_memory.load() - g_allocated_memory.load();
    stats.target_allocation_size = 7ULL * 1024 * 1024 * 1024;
    
    return stats;
}
void NeoSwapRelease(size_t size) {
    // This would be implemented with more sophisticated memory management
    // For now, we just update our tracking
    if (size > g_allocated_memory.load()) {
        size = g_allocated_memory.load();
    }
    
    g_allocated_memory -= size;
}

// Set memory priority for specific allocations
NeoSwapError NeoSwapSetPriority(void* ptr, int priority) {
    if (!ptr || !g_initialized.load()) {
        return NEOSWAP_ERROR_NOT_INITIALIZED;
// Set memory priority for specific allocations
NeoSwapError NeoSwapSetPriority(void* ptr, int priority) {
    if (!ptr || !g_initialized.load()) {
        return NEOSWAP_ERROR_NOT_INITIALIZED;
    }
    
    // Find the allocation and set its priority
    for (auto& block : g_memory_pool) {
        if (block.address == ptr) {
            block.priority = priority;
            
            // Apply to VM
            kern_return_t kr = vm_set_memory_priority(mach_task_self(), 
                (vm_address_t)ptr, block.size, 
                (priority > 0) ? VM_MEMORY_PRIORITY_HIGH : VM_MEMORY_PRIORITY_NORMAL);
            
            return (kr == KERN_SUCCESS) ? NEOSWAP_SUCCESS : NEOSWAP_ERROR_UNKNOWN;
        }
    }
    
    return NEOSWAP_ERROR_INVALID_ARGUMENT;
}
    static char status[256];
    uint64_t allocated = g_allocated_memory.load();
    uint64_t max_alloc = g_max_allocatable_memory.load();
    double percentage = (double)allocated / (double)max_alloc * 100.0;
    
    snprintf(status, sizeof(status), "Allocated: %llu bytes (%.2f%%)", allocated, percentage);
    return status;
}

// Legacy API functions - these are kept for compatibility
const NeoSwapAPI* NeoSwap_GetAPI(uint32_t abi_version) {
    // Return the legacy API for backward compatibility
    static const NeoSwapAPI api = {
        sizeof(NeoSwapAPI),
        NEOSWAP_ABI,
        [](uint32_t owner, uint32_t kind, uint64_t bytes, uint64_t alignment, void** address) -> int {
            // Legacy allocation - use our new implementation
            *address = NeoSwapAllocate(bytes, NEOSWAP_FLAG_NONE);
            return (*address != nullptr) ? NEOSWAP_OK : NEOSWAP_INVALID;
        },
        [](void* address) -> int {
            NeoSwapFree(address);
            return NEOSWAP_OK;
        },
        [](void* address) -> int {
            // No sync needed for our implementation
            return NEOSWAP_OK;
        },
        [](uint32_t owner) -> int {
            // Always enabled for RPCS3
            return 1;
        }
    };
    
    return &api;
}

int NeoSwap_Configure(const char* private_directory, const NeoSwapConfig* config) {
    // Configuration not needed for our implementation
    return NEOSWAP_OK;
}

int NeoSwap_Snapshot(NeoSwapStats* stats) {
    *stats = NeoSwapGetStats();
    return NEOSWAP_OK;
}

void NeoSwap_RegisterClient(uint32_t owner) {
    // Client registration not needed for our implementation
}

uint64_t NeoSwap_LiveBytes(uint32_t owner) {
    // Return current allocated memory
    return g_allocated_memory.load();
}

} // extern "C"
// Relay-backed host loans own their own slot pool so Vulkan buffers, video
// frames and RSX data cannot exhaust the legacy donor/file slots, and the
// reverse. Exhaustion of this pool continues with the legacy pool of the kind.
constexpr size_t relay_block_slots = 1024;
constexpr size_t max_blocks = legacy_block_slots + relay_block_slots;
constexpr uint64_t small_cpu_budget = 512 * MiB;
constexpr uint64_t small_cpu_minimum = 64 * 1024;
constexpr size_t relay_cache_slots = 32;
#if defined(NEOSWAP_RELAY)
// Darwin maps relay intervals on 64 KiB boundaries; loans round up to that so
// the padding is measured instead of silently spent. Reuse cache bounds: the
// bytes parked between a release and the next identical request, and how long
// a parked interval waits before the maintenance pass returns it to the relay.
constexpr uint64_t relay_alignment = 65536;
constexpr uint64_t relay_cache_budget = 128 * MiB;
constexpr uint64_t relay_cache_max_age_ms = 2000;
#endif
// Four diagnostic size bins: [64,128), [128,256), [256,512), [512,1024) KiB.
unsigned cpu_size_bin(uint64_t bytes) noexcept {
    return bytes < 128 * 1024 ? 0 : bytes < 256 * 1024 ? 1 : bytes < 512 * 1024 ? 2 : 3;
}
bool host_kind_supported(uint32_t kind) noexcept {
    return kind == NEOSWAP_HOST_KIND_CPU_DATA || kind == NEOSWAP_HOST_KIND_CPU_CACHE ||
           kind == NEOSWAP_HOST_KIND_GPU_HOST_VISIBLE || kind == NEOSWAP_HOST_KIND_VIDEO_FRAME;
}
struct CPUBufferCounters {
    std::atomic<uint64_t> requests{0}, requested_bytes{0}, successful_allocations{0}, fallback_count{0};
    std::atomic<uint64_t> live_bytes{0}, peak_bytes{0}, live_blocks{0}, allocated_bytes{0};
    std::atomic<uint64_t> pressure_refusals{0}, policy_refusals{0}, pool_misses{0};
    std::array<std::atomic<uint64_t>, 4> request_bins{}, donated_bins{};
    std::atomic<bool> enabled{false}, pressure_raised{true};
};
struct FastCounters {
    std::atomic<uint64_t> requests{0}, successes{0}, broker_busy{0}, donor_busy{0}, ready_misses{0};
    std::atomic<uint64_t> fallback_count{0}, total_time_us{0}, max_time_us{0};
    std::atomic<uint64_t> prepare_requests{0}, prepared_loans{0}, prepare_failures{0};
    std::atomic<uint64_t> retire_requests{0}, retired_loans{0}, retire_failures{0};
};
struct RelayLoanCounters {
    std::atomic<uint64_t> live_bytes{0}, peak_bytes{0}, live_blocks{0}, allocation_count{0};
    std::atomic<uint64_t> quota_bytes{0}, policy_refusals{0}, quota_refusals{0}, backend_refusals{0};
    std::atomic<uint64_t> reuse_hits{0}, cached_bytes{0}, cached_blocks{0}, cache_flushes{0};
    std::atomic<uint64_t> release_failures{0}, padding_bytes{0};
    std::array<std::atomic<uint64_t>, NEOSWAP_HOST_KIND_COUNT> kind_live_bytes{}, kind_live_blocks{};
    std::array<std::atomic<uint64_t>, NEOSWAP_HOST_KIND_COUNT> kind_allocation_count{}, kind_refusal_count{};
    std::atomic<int32_t> last_backend_result{0};
    std::atomic<bool> admitted{false}, video_frames{true};
};
constexpr uint64_t max_block_bytes = 8 * 1024 * MiB;
[[maybe_unused]] constexpr uint64_t max_donation_block_bytes = 256 * MiB;
enum class Backing : uint8_t { none, file, donor, relay };
struct Block {
    void* address = nullptr;
    uint64_t size = 0;
    uint32_t owner = 0;
    uint32_t kind = 0;
    int fd = -1;
    uint64_t donation_token = 0;
    uint64_t relay_token = 0;
    Backing backing = Backing::none;
    bool small_cpu = false;
    // A file allocation owns only this exact region. A rejected allocation
    // whose cleanup failed keeps it here, without exposing a client pointer.
    void* region = nullptr;
    uint64_t region_size = 0;
};
// Released relay loans stay mapped briefly so the next identical request
// reuses the interval without a backend scan, scrub or kernel map.
struct CachedLoan {
    uint64_t token = 0, bytes = 0, released_ms = 0;
    void* address = nullptr;
};
struct HostCounters {
    std::atomic<uint64_t> reserved_virtual_bytes{0}, disk_free_bytes{0}, remaining_storage_bytes{0};
    std::atomic<int32_t> reservation_result{NEOSWAP_OK}, reservation_errno{0};
    std::array<std::atomic<int32_t>, NEOSWAP_OWNER_COUNT> owner_last_result{}, owner_last_errno{};
    std::atomic<uint64_t> donor_pending_demand_bytes{0}, donor_inflight_demand_bytes{0};
    std::atomic<uint64_t> donor_pending_demand_count{0}, donor_demand_overflow_count{0};
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<int32_t>::is_always_lock_free);
// Open-addressing index from client address to block slot. The RSX allocator
// calls release() for every aligned free, so a release must not scan all
// block slots under the broker mutex. Linear probing with backward-shift
// deletion keeps the table tombstone-free; capacity is four times max_blocks.
class AddressIndex {
    static constexpr size_t capacity = max_blocks * 4;
    static constexpr uint16_t empty = 0;
    std::array<uint16_t, capacity> slots_{};
    static size_t hash(const void* address) noexcept {
        auto value = static_cast<uint64_t>(reinterpret_cast<uintptr_t>(address)) >> 12;
        value *= 0x9E3779B97F4A7C15ULL;
        return static_cast<size_t>(value >> 40) % capacity;
    }
public:
    void insert(const void* address, size_t block) noexcept {
        for (size_t i = hash(address);; i = (i + 1) % capacity) {
            if (slots_[i] == empty) { slots_[i] = static_cast<uint16_t>(block + 1); return; }
        }
    }
    bool find(const void* address, const std::array<Block, max_blocks>& blocks, size_t& block) const noexcept {
        for (size_t i = hash(address);; i = (i + 1) % capacity) {
            if (slots_[i] == empty) return false;
            const size_t candidate = slots_[i] - 1;
            if (blocks[candidate].address == address) { block = candidate; return true; }
        }
    }
    void erase(const void* address, const std::array<Block, max_blocks>& blocks) noexcept {
        size_t i = hash(address);
        for (;; i = (i + 1) % capacity) {
            if (slots_[i] == empty) return;
            if (blocks[slots_[i] - 1].address == address) break;
        }
        size_t j = i;
        for (;;) {
            j = (j + 1) % capacity;
            if (slots_[j] == empty) break;
            const size_t k = hash(blocks[slots_[j] - 1].address);
            const bool keep = i <= j ? (i < k && k <= j) : (i < k || k <= j);
            if (keep) continue;
            slots_[i] = slots_[j];
            i = j;
        }
        slots_[i] = empty;
    }
};
struct Broker {
    std::mutex mutex;
    std::array<Block, max_blocks> blocks{};
    // Exact address publication, independent of the mutex-protected hash index.
    // Low bit marks a fast loan. Cleanup withdraws it before the OS unmap;
    // failure republishes ownership. Heap frees never wait on maintenance.
    std::array<std::atomic<uintptr_t>, max_blocks> owned_addresses{};
    std::array<std::atomic<bool>, max_blocks> pending_releases{};
    std::array<std::atomic<uint64_t>, (max_blocks + 63) / 64> owned_bits{};
    size_t next_release = 0;
    AddressIndex index{};
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
    RelayLoanCounters relay_loans{};
    FastCounters fast{};
    // Bounded hints, not reservations. Only the maintenance queue maps them.
    std::array<uint64_t, 8> pending_relay_bytes{};
    std::array<CachedLoan, relay_cache_slots> relay_cache{};
    int directory = -1;
    uint64_t next_name = 1;
    uint64_t file_live_bytes = 0, shared_live_bytes = 0, relay_live_bytes = 0;
    std::atomic<uint32_t> enabled_mask{0}, live_count{0}, active_session_mask{0};
#if defined(NEOSWAP_DONATION)
    std::atomic<uint32_t> donation_enabled_mask{0};
#endif
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_bytes{};
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_donated_bytes{};
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_relay_bytes{};
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
#if defined(NEOSWAP_RELAY)
const NeoSwapRelayAPI* relay_api() {
    static const NeoSwapRelayAPI* api = NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI);
    return api;
}
constexpr uint32_t relay_host_loan_owner = 1; // neostation::relay::host_loan_owner
#endif
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
        out->owner_relay_live_bytes[i] = b.owner_relay_bytes[i].load(std::memory_order_relaxed);
    }
    out->relay_loan_live_bytes = b.relay_loans.live_bytes.load(std::memory_order_relaxed);
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
                      uint32_t owner, uint32_t kind, Backing backing, int fd, uint64_t token,
                      std::chrono::steady_clock::time_point started, void** out, bool fast = false) {
    // Preserve the file region acquired before MAP_FIXED; a donor has none.
    slot.address = address; slot.size = size; slot.owner = owner; slot.kind = kind;
    slot.fd = fd; slot.backing = backing;
    slot.donation_token = backing == Backing::donor ? token : 0;
    slot.relay_token = backing == Backing::relay ? token : 0;
    if (backing == Backing::donor) {
        b.shared_live_bytes += size;
        b.owner_donated_bytes[owner].fetch_add(size, std::memory_order_relaxed);
    } else if (backing == Backing::relay) {
        b.relay_live_bytes += size;
        b.owner_relay_bytes[owner].fetch_add(size, std::memory_order_relaxed);
        auto& r = b.relay_loans;
        const uint64_t live = r.live_bytes.fetch_add(size, std::memory_order_relaxed) + size;
        r.peak_bytes.store(std::max(live, r.peak_bytes.load(std::memory_order_relaxed)), std::memory_order_relaxed);
        r.live_blocks.fetch_add(1, std::memory_order_relaxed);
        r.allocation_count.fetch_add(1, std::memory_order_relaxed);
        r.kind_live_bytes[kind].fetch_add(size, std::memory_order_relaxed);
        r.kind_live_blocks[kind].fetch_add(1, std::memory_order_relaxed);
        r.kind_allocation_count[kind].fetch_add(1, std::memory_order_relaxed);
    }
    else b.file_live_bytes += size;
    const auto slot_index = static_cast<size_t>(&slot - b.blocks.data());
    b.index.insert(address, slot_index);
    b.owned_addresses[slot_index].store(reinterpret_cast<uintptr_t>(address) | (fast ? uintptr_t{1} : 0),
                                       std::memory_order_release);
    b.owned_bits[slot_index / 64].fetch_or(uint64_t{1} << (slot_index % 64), std::memory_order_release);
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
Block* find_slot(Broker& b, size_t first, size_t last) {
    for (size_t i = first; i < last; ++i) {
        auto& item = b.blocks[i];
        if (!item.address && !item.region) return &item;
    }
    return nullptr;
}
#if defined(NEOSWAP_RELAY)
// Retire one cached loan (unmap + release). A failed unmap retains the
// cached entry for a later retry; a failed release after a successful unmap
// hands the token to the backend's retirement path, which retries scrubbing.
bool retire_cached_loan(Broker& b, CachedLoan& cached) {
    const auto* api = relay_api();
    if (!api) return false;
    const int unmapped = api->unmap(cached.token, cached.address);
    if (unmapped != NEOSWAP_RELAY_OK) {
        b.relay_loans.release_failures.fetch_add(1, std::memory_order_relaxed);
        b.relay_loans.last_backend_result.store(unmapped, std::memory_order_relaxed);
        return false;
    }
    if (api->release(cached.token) != NEOSWAP_RELAY_OK) {
        b.relay_loans.release_failures.fetch_add(1, std::memory_order_relaxed);
        (void)api->retire(cached.token);
    }
    b.relay_loans.cached_bytes.fetch_sub(cached.bytes, std::memory_order_relaxed);
    b.relay_loans.cached_blocks.fetch_sub(1, std::memory_order_relaxed);
    b.relay_loans.cache_flushes.fetch_add(1, std::memory_order_relaxed);
    cached = {};
    return true;
}
void relay_refuse(Broker& b, uint32_t kind, std::atomic<uint64_t>& counter) {
    counter.fetch_add(1, std::memory_order_relaxed);
    b.relay_loans.kind_refusal_count[kind].fetch_add(1, std::memory_order_relaxed);
}
// Borrow a relay-backed host interval. Pages belong to retained named objects
// whose creator exited; the host footprint is not charged for them. Any
// refusal returns false and the caller continues with donors or files.
bool try_relay_loan(Broker& b, uint32_t owner, uint32_t kind, uint64_t rounded, Block*& slot,
                    void** out, std::chrono::steady_clock::time_point started, bool fast = false) {
    auto& r = b.relay_loans;
    const auto* api = relay_api();
    if (!api) return false;
    if (!r.admitted.load(std::memory_order_acquire) ||
        (kind == NEOSWAP_HOST_KIND_VIDEO_FRAME && !r.video_frames.load(std::memory_order_acquire))) {
        relay_refuse(b, kind, r.policy_refusals);
        return false;
    }
    const uint64_t bytes = (rounded + relay_alignment - 1) & ~(relay_alignment - 1);
    if (!slot) {
        slot = find_slot(b, legacy_block_slots, max_blocks);
        if (!slot) {
            const size_t first = kind == NEOSWAP_HOST_KIND_CPU_CACHE ? large_block_slots : 0;
            const size_t last = kind == NEOSWAP_HOST_KIND_CPU_CACHE ? legacy_block_slots : large_block_slots;
            slot = find_slot(b, first, last);
        }
        if (!slot) { relay_refuse(b, kind, r.policy_refusals); return false; }
    }
    for (auto& cached : b.relay_cache) if (cached.token && cached.bytes == bytes) {
        r.reuse_hits.fetch_add(1, std::memory_order_relaxed);
        r.cached_bytes.fetch_sub(bytes, std::memory_order_relaxed);
        r.cached_blocks.fetch_sub(1, std::memory_order_relaxed);
        r.padding_bytes.fetch_add(bytes - rounded, std::memory_order_relaxed);
        const uint64_t token = cached.token;
        void* address = cached.address;
        cached = {};
        record_allocation(b, *slot, address, bytes, owner, kind, Backing::relay, -1, token, started, out, fast);
        return true;
    }
    if (fast) {
        // Never let a miss reach create/map/scrub or a slow fallback. The
        // existing maintenance timer can prepare one requested size off-frame.
        if (bytes <= 16 * MiB) {
            bool queued = false;
            for (const auto demand : b.pending_relay_bytes) queued |= demand == bytes;
            if (!queued) for (auto& demand : b.pending_relay_bytes) if (!demand) {
                demand = bytes;
                b.fast.prepare_requests.fetch_add(1, std::memory_order_relaxed);
                break;
            }
        }
        return false;
    }
    // A reuse hit above is already charged. A new interval is charged the way
    // the backend charges owner 1: live intervals plus those still parked in
    // the reuse cache, which remain mapped and owned until maintenance.
    const uint64_t quota = r.quota_bytes.load(std::memory_order_acquire);
    const uint64_t charged = r.live_bytes.load(std::memory_order_relaxed) +
                             r.cached_bytes.load(std::memory_order_relaxed);
    if (charged >= quota || bytes > quota - charged) {
        relay_refuse(b, kind, r.quota_refusals);
        return false;
    }
    uint64_t token = 0;
    int result = api->create(relay_host_loan_owner, bytes, &token);
    if (result != NEOSWAP_RELAY_OK || !token) {
        r.last_backend_result.store(result, std::memory_order_relaxed);
        relay_refuse(b, kind, r.backend_refusals);
        return false;
    }
    void* address = nullptr;
    result = api->map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &address);
    if (result != NEOSWAP_RELAY_OK || !address) {
        r.last_backend_result.store(result == NEOSWAP_RELAY_OK ? NEOSWAP_RELAY_MAPPING : result,
                                    std::memory_order_relaxed);
        if (api->release(token) != NEOSWAP_RELAY_OK) (void)api->retire(token);
        relay_refuse(b, kind, r.backend_refusals);
        return false;
    }
    r.padding_bytes.fetch_add(bytes - rounded, std::memory_order_relaxed);
    record_allocation(b, *slot, address, bytes, owner, kind, Backing::relay, -1, token, started, out, fast);
    return true;
}
// Returns NEOSWAP_OK when the block's relay interval is cached or released,
// otherwise the failure that retains ownership of the live mapping.
int release_relay_loan(Broker& b, Block& block, uint64_t now_ms) {
    auto& r = b.relay_loans;
    const auto* api = relay_api();
    if (!api) return NEOSWAP_MAPPING;
    if (r.admitted.load(std::memory_order_acquire) &&
        r.cached_bytes.load(std::memory_order_relaxed) + block.size <= relay_cache_budget) {
        for (auto& cached : b.relay_cache) if (!cached.token) {
            cached = {block.relay_token, block.size, now_ms, block.address};
            r.cached_bytes.fetch_add(block.size, std::memory_order_relaxed);
            r.cached_blocks.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_OK;
        }
    }
    const int unmapped = api->unmap(block.relay_token, block.address);
    if (unmapped != NEOSWAP_RELAY_OK) {
        r.release_failures.fetch_add(1, std::memory_order_relaxed);
        r.last_backend_result.store(unmapped, std::memory_order_relaxed);
        return NEOSWAP_MAPPING;
    }
    if (api->release(block.relay_token) != NEOSWAP_RELAY_OK) {
        r.release_failures.fetch_add(1, std::memory_order_relaxed);
        (void)api->retire(block.relay_token);
    }
    return NEOSWAP_OK;
}
uint64_t monotonic_ms() {
    return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count());
}
#endif
int allocate(uint32_t owner, uint32_t kind, uint64_t bytes, uint64_t alignment, void** out) {
    if (!out) return NEOSWAP_INVALID;
    *out = nullptr;
    // Legacy ABI slots are reserved, never eligible clients. Refuse before
    // broker locks, file creation, donor demand or allocation accounting.
    if (owner >= NEOSWAP_OWNER_COUNT) return NEOSWAP_INVALID;
    if (owner != NEOSWAP_RPCS3) return NEOSWAP_DISABLED;
    auto& b = broker();
    const bool fast = (kind & NEOSWAP_REQUEST_FAST) != 0;
    kind &= ~static_cast<uint32_t>(NEOSWAP_REQUEST_FAST);
    struct FastAttempt {
        FastCounters* counters;
        void** output;
        std::chrono::steady_clock::time_point start;
        ~FastAttempt() {
            if (!counters) return;
            const auto us = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
                std::chrono::steady_clock::now() - start).count());
            counters->total_time_us.fetch_add(us, std::memory_order_relaxed);
            auto maximum = counters->max_time_us.load(std::memory_order_relaxed);
            while (maximum < us && !counters->max_time_us.compare_exchange_weak(maximum, us, std::memory_order_relaxed)) {}
            (*output ? counters->successes : counters->fallback_count).fetch_add(1, std::memory_order_relaxed);
        }
    } fast_attempt{fast ? &b.fast : nullptr, out, std::chrono::steady_clock::now()};
    if (fast) b.fast.requests.fetch_add(1, std::memory_order_relaxed);
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
    std::unique_lock guard(b.mutex, std::defer_lock);
    if (fast) {
        if (!guard.try_lock()) {
            b.fast.broker_busy.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_BUSY;
        }
    } else guard.lock();
    if (owner >= NEOSWAP_OWNER_COUNT || !host_kind_supported(kind) ||
        !bytes || !power_of_two(alignment) || alignment > 65536 || bytes > max_block_bytes)
        return reject(b, owner, NEOSWAP_INVALID);
    const bool video_frame = kind == NEOSWAP_HOST_KIND_VIDEO_FRAME;
    bool donor_enabled = false;
#if defined(NEOSWAP_DONATION)
    donor_enabled = owner == NEOSWAP_RPCS3 && b.donation_config.capacity_bytes &&
        (b.donation_config.enabled_owner_mask & (1u << owner)) && donation_ready();
#endif
    const bool file_enabled = b.config.capacity_bytes && b.directory >= 0 &&
        (b.config.enabled_owner_mask & (1u << owner));
    bool relay_enabled = false;
#if defined(NEOSWAP_RELAY)
    relay_enabled = owner == NEOSWAP_RPCS3 && b.relay_loans.admitted.load(std::memory_order_acquire);
#endif
    if (!file_enabled && !donor_enabled && !relay_enabled)
        return reject(b, owner, NEOSWAP_DISABLED);
    uint64_t minimum = b.config.minimum_allocation_bytes;
#if defined(NEOSWAP_DONATION)
    if (donor_enabled) minimum = b.donation_config.minimum_allocation_bytes;
#endif
    if (!file_enabled && !donor_enabled) minimum = MiB;
    if (small_cpu) {
        // Small CPU data borrows verified RAM only; never create hundreds of
        // small swap files or consume the 256 legacy large-allocation slots.
        if (!cpu.enabled.load(std::memory_order_acquire) || cpu.pressure_raised.load(std::memory_order_acquire)) {
            cpu.pressure_refusals.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_DISABLED;
        }
        minimum = small_cpu_minimum;
    }
    // Video frames are RAM-only loans of any size at or above the relay page:
    // the decoder keeps its ordinary anonymous mapping on refusal.
    if (video_frame) minimum = small_cpu_minimum;
    if (bytes < minimum) return reject(b, owner, NEOSWAP_TOO_SMALL);
    const long page_long = ::sysconf(_SC_PAGESIZE);
    if (page_long <= 0 || !power_of_two(static_cast<uint64_t>(page_long)))
        return reject(b, owner, NEOSWAP_MAPPING, EINVAL);
    const auto page = static_cast<uint64_t>(page_long);
    const uint64_t rounded = (bytes + page - 1) & ~(page - 1);
    Block* slot = nullptr;
    if (small_cpu && (cpu.live_bytes.load(std::memory_order_relaxed) > small_cpu_budget ||
        rounded > small_cpu_budget - cpu.live_bytes.load(std::memory_order_relaxed))) {
        cpu.policy_refusals.fetch_add(1, std::memory_order_relaxed);
        return reject(b, owner, NEOSWAP_QUOTA);
    }
    const auto started = std::chrono::steady_clock::now();
    const auto note_small_cpu = [&](Block& used) {
        if (!small_cpu) return;
        used.small_cpu = true;
        const uint64_t live = cpu.live_bytes.fetch_add(used.size, std::memory_order_relaxed) + used.size;
        cpu.peak_bytes.store(std::max(live, cpu.peak_bytes.load(std::memory_order_relaxed)), std::memory_order_relaxed);
        cpu.live_blocks.fetch_add(1, std::memory_order_relaxed);
        cpu.allocated_bytes.fetch_add(used.size, std::memory_order_relaxed);
        cpu.successful_allocations.fetch_add(1, std::memory_order_relaxed);
        cpu.donated_bins[cpu_size_bin(bytes)].fetch_add(1, std::memory_order_relaxed);
        attempt.success = true;
    };
    (void)note_small_cpu; // file-only builds have no RAM path for small CPU data
#if defined(NEOSWAP_RELAY)
    // Relay host loans come first: shared named-object pages outside the host
    // footprint, bounded by the global budget quota (not by the file/donor
    // capacity below), with cached reuse.
    if (relay_enabled && b.next_name != std::numeric_limits<uint64_t>::max()) {
        Block* relay_slot = nullptr;
        if (try_relay_loan(b, owner, kind, rounded, relay_slot, out, started, fast)) {
            note_small_cpu(*relay_slot);
            return NEOSWAP_OK;
        }
    }
#endif
    // Only files and donors remain; a demand hint for a not-yet-ready donor
    // pool is still queued below when a donation policy exists.
    if (!file_enabled && !donor_enabled) return reject(b, owner, NEOSWAP_DISABLED);
    // The configured capacity bounds file and donor bytes; relay loans are
    // charged to their own quota and excluded here.
    const auto capacity = effective_capacity(b);
    const uint64_t charged = b.stats.live_bytes - b.relay_live_bytes;
    if (charged > capacity || rounded > capacity - charged)
        return reject(b, owner, NEOSWAP_QUOTA);
    const size_t first_slot = small_cpu ? large_block_slots : 0;
    const size_t last_slot = small_cpu ? legacy_block_slots : large_block_slots;
    slot = find_slot(b, first_slot, last_slot);
    if (!slot || b.next_name == std::numeric_limits<uint64_t>::max()) return reject(b, owner, NEOSWAP_LIMIT);
#if defined(NEOSWAP_DONATION)
    // Borrow only a verified helper-owned object, entirely locally. Never wait
    // for extension launch/XPC on an RPCS3 thread.
    if (donor_enabled) {
        void* donated = nullptr;
        uint64_t token = 0;
        const auto acquired = neostation::donation::pool_acquire(rounded, std::max(alignment, page), &donated, &token);
        if (acquired) {
            const int result = record_allocation(b, *slot, donated, rounded, owner, kind, Backing::donor, -1, token, started, out, fast);
            note_small_cpu(*slot);
            return result;
        }
        if (fast && acquired.stage == neostation::donation::Stage::pool_busy)
            b.fast.donor_busy.fetch_add(1, std::memory_order_relaxed);
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
    if (fast) {
        b.fast.ready_misses.fetch_add(1, std::memory_order_relaxed);
        return reject(b, owner, NEOSWAP_BUSY); // caller immediately uses its ordinary allocation
    }
    if (small_cpu) return reject(b, owner, NEOSWAP_DISABLED); // no disk fallback for sub-MiB CPU requests
    if (video_frame) return reject(b, owner, NEOSWAP_DISABLED); // frames never wait for or use files
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
    return record_allocation(b, *slot, p, rounded, owner, kind, Backing::file, fd, 0, started, out);
}
int release_locked(Broker& b, size_t found) {
    Block& block = b.blocks[found];
    // Withdraw before an OS unmap can recycle this address for an ordinary
    // allocation. On failure the backend retains its mapping, so republish
    // exact ownership. No new object can use this slot while we hold the lock.
    struct OwnershipWithdrawal {
        Broker& broker;
        size_t slot;
        uintptr_t owned;
        bool released = false;
        ~OwnershipWithdrawal() {
            if (released) return;
            broker.owned_addresses[slot].store(owned, std::memory_order_release);
            broker.owned_bits[slot / 64].fetch_or(uint64_t{1} << (slot % 64), std::memory_order_release);
        }
    } withdrawal{b, found, b.owned_addresses[found].exchange(0, std::memory_order_acq_rel)};
    b.owned_bits[found / 64].fetch_and(~(uint64_t{1} << (found % 64)), std::memory_order_release);
    switch (block.backing) {
#if defined(NEOSWAP_DONATION)
    case Backing::donor: {
        auto result = neostation::donation::pool_release(block.donation_token);
        if (!result) {
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
            b.stats.last_errno = result.kernel_result;
            return NEOSWAP_MAPPING; // preserve ownership; do not heap-free it
        }
        break;
    }
#endif
#if defined(NEOSWAP_RELAY)
    case Backing::relay: {
        const int result = release_relay_loan(b, block, monotonic_ms());
        if (result != NEOSWAP_OK) {
            ++b.stats.io_errors; b.stats.last_result = result;
            b.stats.last_errno = b.relay_loans.last_backend_result.load(std::memory_order_relaxed);
            return result; // the live relay mapping stays owned
        }
        break;
    }
#endif
    default:
        // Release only our recorded interval. A failed unmap retains the live
        // pointer and file; a successful release never remaps that address.
        if (fail(b, 4) || discard_region(b, block)) {
            reservation_error(b, errno);
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
            b.stats.last_errno = errno; return NEOSWAP_MAPPING; // retain descriptor/ownership
        }
        break;
    }
    const int fd = block.fd;
    if (block.small_cpu) {
        b.cpu_buffers.live_bytes.fetch_sub(block.size, std::memory_order_relaxed);
        b.cpu_buffers.live_blocks.fetch_sub(1, std::memory_order_relaxed);
    }
    if (block.backing == Backing::donor) {
        b.shared_live_bytes -= block.size;
        b.owner_donated_bytes[block.owner].fetch_sub(block.size, std::memory_order_relaxed);
    } else if (block.backing == Backing::relay) {
        b.relay_live_bytes -= block.size;
        b.owner_relay_bytes[block.owner].fetch_sub(block.size, std::memory_order_relaxed);
        auto& r = b.relay_loans;
        r.live_bytes.fetch_sub(block.size, std::memory_order_relaxed);
        r.live_blocks.fetch_sub(1, std::memory_order_relaxed);
        r.kind_live_bytes[block.kind].fetch_sub(block.size, std::memory_order_relaxed);
        r.kind_live_blocks[block.kind].fetch_sub(1, std::memory_order_relaxed);
    }
    else b.file_live_bytes -= block.size;
    b.stats.live_bytes -= block.size; --b.stats.live_blocks;
    b.stats.owners[block.owner].live_bytes -= block.size;
    b.owner_bytes[block.owner].store(b.stats.owners[block.owner].live_bytes, std::memory_order_relaxed);
    b.index.erase(block.address, b.blocks);
    withdrawal.released = true;
    block = Block{};
    b.live_count.store(static_cast<uint32_t>(b.stats.live_blocks), std::memory_order_release);
    // No retry of close(): its descriptor may already have been recycled.
    if (fd >= 0 && ::close(fd)) { ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno; }
    return NEOSWAP_OK;
}
int release(void* p) {
    if (!p) return NEOSWAP_NOT_OWNED;
    auto& b = broker();
    if (!b.live_count.load(std::memory_order_acquire)) return NEOSWAP_NOT_OWNED;
    const auto address = reinterpret_cast<uintptr_t>(p);
    size_t found = max_blocks;
    // 32 bitmap words at the hard maximum, then only occupied slots; never
    // scan all 2048 address atomics for each ordinary small heap free.
    for (size_t word = 0; word < b.owned_bits.size() && found == max_blocks; ++word) {
      auto bits = b.owned_bits[word].load(std::memory_order_acquire);
      while (bits) {
        const size_t index = word * 64 + std::countr_zero(bits);
        bits &= bits - 1;
        const auto owned = b.owned_addresses[index].load(std::memory_order_acquire);
        if (!owned || (owned & ~uintptr_t{1}) != address) continue;
        if (owned & 1) {
            // The caller quiesced all users and relinquishes the pointer.
            // Keep its backing and quota until maintenance has really released
            // it; never turn a failed cleanup into an ordinary free/unmap.
            if (!b.pending_releases[index].exchange(true, std::memory_order_release))
                b.fast.retire_requests.fetch_add(1, std::memory_order_relaxed);
            return NEOSWAP_OK;
        }
        found = index;
        break;
      }
    }
    if (found == max_blocks) return NEOSWAP_NOT_OWNED;
    std::lock_guard guard(b.mutex);
    if (!b.index.find(p, b.blocks, found)) return NEOSWAP_NOT_OWNED;
    return release_locked(b, found);
}
void maintain_fast_releases_locked(Broker& b) {
    unsigned remaining = 32;
    const size_t first = b.next_release;
    for (size_t scanned = 0; scanned < max_blocks && remaining; ++scanned) {
        const size_t index = (first + scanned) % max_blocks;
        if (!b.pending_releases[index].exchange(false, std::memory_order_acquire)) continue;
        --remaining;
        b.next_release = (index + 1) % max_blocks;
        if (release_locked(b, index) == NEOSWAP_OK)
            b.fast.retired_loans.fetch_add(1, std::memory_order_relaxed);
        else {
            // No address can be reissued while failed cleanup remains owned.
            b.pending_releases[index].store(true, std::memory_order_release);
            b.fast.retire_failures.fetch_add(1, std::memory_order_relaxed);
        }
    }
}
int sync(void* p) {
    auto& b = broker(); std::lock_guard guard(b.mutex);
    size_t found = 0;
    if (!p || !b.index.find(p, b.blocks, found)) return NEOSWAP_NOT_OWNED;
    const Block& block = b.blocks[found];
    if (block.backing != Backing::file) {
        std::atomic_thread_fence(std::memory_order_seq_cst);
        return NEOSWAP_OK; // shared RAM has no backing file to flush
    }
    if (fail(b, 5) || ::msync(p, block.size, MS_SYNC)) {
        ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno;
        return NEOSWAP_IO;
    }
    return NEOSWAP_OK;
}
int enabled(uint32_t owner) {
    if (owner != NEOSWAP_RPCS3) return 0;
    auto& b = broker();
    if (b.enabled_mask.load(std::memory_order_acquire) & (1u << owner)) return 1;
#if defined(NEOSWAP_RELAY)
    if (b.relay_loans.admitted.load(std::memory_order_acquire)) return 1;
#endif
#if defined(NEOSWAP_DONATION)
    // Do not make a verified donor depend on a successful file-cache policy.
    if (owner == NEOSWAP_RPCS3 && donation_ready()) {
        return (b.donation_enabled_mask.load(std::memory_order_acquire) & (1u << owner)) != 0;
    }
#endif
    return 0;
}
const NeoSwapAPI api{sizeof(NeoSwapAPI), NEOSWAP_ABI, allocate, release, sync, enabled};
#if defined(NEOSWAP_RELAY)
int relay_loan_maintain_locked(Broker& b, uint64_t now_ms, bool flush_all) {
    int failures = 0;
    for (auto& cached : b.relay_cache) {
        if (!cached.token) continue;
        const uint64_t age_ms = now_ms > cached.released_ms ? now_ms - cached.released_ms : 0;
        if (!flush_all && age_ms <= relay_cache_max_age_ms) continue;
        if (!retire_cached_loan(b, cached)) ++failures;
    }
    return failures ? NEOSWAP_MAPPING : NEOSWAP_OK;
}
#endif
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
#if defined(NEOSWAP_DONATION) || defined(NEOSWAP_RELAY)
    if (owner == NEOSWAP_RPCS3) {
        std::lock_guard guard(b.mutex);
#if defined(NEOSWAP_DONATION)
        b.inflight_demand = {};
        for (auto& queued : b.pending_demands) queued = {};
        publish_demands(b);
#endif
#if defined(NEOSWAP_RELAY)
        // Session end: no new relay loans and no retained reuse cache. Live
        // client blocks keep their mappings until the Core releases them.
        b.relay_loans.admitted.store(false, std::memory_order_release);
        (void)relay_loan_maintain_locked(b, monotonic_ms(), true);
#endif
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
extern "C" void NeoSwap_TestWithBrokerLock(void (*callback)(void*), void* context) {
    auto& b = broker(); std::lock_guard guard(b.mutex); callback(context);
}
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

extern "C" int NeoSwap_FastSnapshot(NeoSwapFastStats* output) {
    if (!output) return NEOSWAP_INVALID;
    const auto& f = broker().fast;
#define COPY_FAST(name) output->name = f.name.load(std::memory_order_relaxed)
    COPY_FAST(requests); COPY_FAST(successes); COPY_FAST(broker_busy); COPY_FAST(donor_busy);
    COPY_FAST(ready_misses); COPY_FAST(fallback_count); COPY_FAST(total_time_us); COPY_FAST(max_time_us);
    COPY_FAST(prepare_requests); COPY_FAST(prepared_loans); COPY_FAST(prepare_failures);
    COPY_FAST(retire_requests); COPY_FAST(retired_loans); COPY_FAST(retire_failures);
#undef COPY_FAST
    return NEOSWAP_OK;
}
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
extern "C" int NeoSwap_SetRelayHostLoanPolicy(uint64_t quota_bytes, int admitted, int video_frames) {
#if defined(NEOSWAP_RELAY)
    auto& r = broker().relay_loans;
    r.quota_bytes.store(quota_bytes, std::memory_order_release);
    r.video_frames.store(video_frames != 0, std::memory_order_release);
    r.admitted.store(admitted != 0 && relay_api() != nullptr, std::memory_order_release);
    return NEOSWAP_OK;
#else
    (void)quota_bytes; (void)admitted; (void)video_frames; return NEOSWAP_DISABLED;
#endif
}
extern "C" int NeoSwap_RelayLoanMaintain(uint64_t now_ms, int flush_all) {
    auto& b = broker(); std::lock_guard guard(b.mutex);
    maintain_fast_releases_locked(b);
#if defined(NEOSWAP_RELAY)
    // Releases stamp cached intervals with the broker's monotonic clock; ages
    // are only meaningful against that same clock, so 0 selects it.
    if (!now_ms) now_ms = monotonic_ms();
    // The caller decides when to drain (no session, shrinking, pressure); a
    // closed admission gate alone keeps the bounded cache ageing normally so
    // a holding sample does not hand room back and reopen the gate.
    const int result = relay_loan_maintain_locked(b, now_ms, flush_all != 0);
    if (flush_all) {
        b.pending_relay_bytes.fill(0);
        return result;
    }
    // One bounded mapping per existing background tick; no new worker/thread.
    // Host cache limits and the backend quota include these prepared intervals.
    if (!b.relay_loans.admitted.load(std::memory_order_acquire)) return result;
    const auto* api = relay_api();
    for (auto& demand : b.pending_relay_bytes) if (demand) {
        const uint64_t bytes = demand;
        const uint64_t cached_bytes = b.relay_loans.cached_bytes.load(std::memory_order_relaxed);
        const uint64_t live_bytes = b.relay_loans.live_bytes.load(std::memory_order_relaxed);
        const uint64_t quota = b.relay_loans.quota_bytes.load(std::memory_order_relaxed);
        CachedLoan* slot = nullptr;
        for (auto& cached : b.relay_cache) {
            if (cached.token && cached.bytes == bytes) { demand = 0; break; }
            if (!cached.token && !slot) slot = &cached;
        }
        if (!demand) continue;
        if (cached_bytes + bytes > relay_cache_budget || live_bytes + cached_bytes > quota ||
            bytes > quota - live_bytes - cached_bytes) continue; // a large hint must not starve smaller sizes
        if (!slot || !api) break;
        demand = 0;
        uint64_t token = 0;
        void* address = nullptr;
        int prepared = api->create(relay_host_loan_owner, bytes, &token);
        if (prepared == NEOSWAP_RELAY_OK && token)
            prepared = api->map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &address);
        if (prepared == NEOSWAP_RELAY_OK && address) {
            *slot = {token, bytes, now_ms, address};
            b.relay_loans.cached_bytes.fetch_add(bytes, std::memory_order_relaxed);
            b.relay_loans.cached_blocks.fetch_add(1, std::memory_order_relaxed);
            b.fast.prepared_loans.fetch_add(1, std::memory_order_relaxed);
        } else {
            if (token && api->release(token) != NEOSWAP_RELAY_OK) (void)api->retire(token);
            b.fast.prepare_failures.fetch_add(1, std::memory_order_relaxed);
        }
        break;
    }
    return result;
#else
    (void)now_ms; (void)flush_all; return NEOSWAP_DISABLED;
#endif
}
extern "C" int NeoSwap_RelayLoanSnapshot(NeoSwapRelayLoanStats* output) {
    if (!output) return NEOSWAP_INVALID;
    *output = {};
    const auto& r = broker().relay_loans;
#define COPY_RELAY_FIELD(name) output->name = r.name.load(std::memory_order_relaxed)
    COPY_RELAY_FIELD(live_bytes); COPY_RELAY_FIELD(peak_bytes); COPY_RELAY_FIELD(live_blocks);
    COPY_RELAY_FIELD(allocation_count); COPY_RELAY_FIELD(quota_bytes); COPY_RELAY_FIELD(policy_refusals);
    COPY_RELAY_FIELD(quota_refusals); COPY_RELAY_FIELD(backend_refusals); COPY_RELAY_FIELD(reuse_hits);
    COPY_RELAY_FIELD(cached_bytes); COPY_RELAY_FIELD(cached_blocks); COPY_RELAY_FIELD(cache_flushes);
    COPY_RELAY_FIELD(release_failures); COPY_RELAY_FIELD(padding_bytes); COPY_RELAY_FIELD(last_backend_result);
#undef COPY_RELAY_FIELD
    for (size_t kind = 0; kind < NEOSWAP_HOST_KIND_COUNT; ++kind) {
        output->kind_live_bytes[kind] = r.kind_live_bytes[kind].load(std::memory_order_relaxed);
        output->kind_live_blocks[kind] = r.kind_live_blocks[kind].load(std::memory_order_relaxed);
        output->kind_allocation_count[kind] = r.kind_allocation_count[kind].load(std::memory_order_relaxed);
        output->kind_refusal_count[kind] = r.kind_refusal_count[kind].load(std::memory_order_relaxed);
    }
    output->admitted = r.admitted.load(std::memory_order_relaxed);
    output->video_frames_admitted = r.video_frames.load(std::memory_order_relaxed);
#if defined(NEOSWAP_RELAY)
    output->available = relay_api() != nullptr;
#else
    output->available = 0;
#endif
    return NEOSWAP_OK;
}
