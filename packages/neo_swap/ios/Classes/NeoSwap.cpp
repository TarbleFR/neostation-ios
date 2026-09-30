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
constexpr size_t max_blocks = 256;
constexpr uint64_t max_block_bytes = 256 * MiB;
struct Block {
    void* address = nullptr;
    uint64_t size = 0;
    uint32_t owner = 0;
    int fd = -1;
    uint64_t donation_token = 0;
};
struct HostCounters {
    std::atomic<uint64_t> reserved_virtual_bytes{0}, disk_free_bytes{0}, remaining_storage_bytes{0};
    std::atomic<int32_t> reservation_result{NEOSWAP_OK}, reservation_errno{0};
    std::array<std::atomic<int32_t>, NEOSWAP_OWNER_COUNT> owner_last_result{}, owner_last_errno{};
};
static_assert(std::atomic<uint64_t>::is_always_lock_free && std::atomic<int32_t>::is_always_lock_free);
struct Broker {
    std::mutex mutex;
    std::array<Block, max_blocks> blocks{};
    NeoSwapConfig config{};
#if defined(NEOSWAP_DONATION)
    NeoSwapConfig donation_config{};
#endif
    NeoSwapStats stats{};
    HostCounters host_stats{};
    void* arena = nullptr;
    size_t arena_size = 0;
    int directory = -1;
    uint64_t next_name = 1;
    uint64_t file_live_bytes = 0, shared_live_bytes = 0;
    std::atomic<uint32_t> enabled_mask{0}, live_count{0};
#if defined(NEOSWAP_DONATION)
    std::atomic<uint32_t> donation_enabled_mask{0};
#endif
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_bytes{};
#ifdef NEOSWAP_TESTING
    int failure = 0;
#endif
    ~Broker() {
        for (auto& b : blocks) {
            if (b.address && b.fd >= 0) ::close(b.fd);
        }
        if (arena) ::munmap(arena, arena_size);
        if (directory >= 0) ::close(directory);
    }
};
Broker& broker() { static Broker b; return b; }
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
    }
    out->donated_live_bytes = out->donor_prepared_bytes = out->donor_footprint_bytes = 0;
    out->donor_nonvolatile_bytes = out->donor_compressed_bytes = out->donor_generation = 0;
    out->donor_pid = out->donation_state = out->donation_last_stage = out->donation_last_kernel_result = 0;
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
void* reserve_arena(size_t bytes) {
    // All supported client alignments fit in the quota, including a completely
    // full capacity test. Align the arena itself without charging padding.
    constexpr size_t alignment = 65536;
    const size_t span = bytes + alignment;
    void* original = ::mmap(nullptr, span, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (original == MAP_FAILED) return MAP_FAILED;
    const uintptr_t start = reinterpret_cast<uintptr_t>(original);
    const uintptr_t aligned = (start + alignment - 1) & ~(alignment - 1);
    const size_t prefix = aligned - start;
    const size_t suffix = span - prefix - bytes;
    if (prefix && ::munmap(original, prefix)) {
        const int error = errno; ::munmap(original, span); errno = error; return MAP_FAILED;
    }
    if (suffix && ::munmap(reinterpret_cast<void*>(aligned + bytes), suffix)) {
        const int error = errno;
        ::munmap(reinterpret_cast<void*>(aligned), span - prefix);
        errno = error; return MAP_FAILED;
    }
    return reinterpret_cast<void*>(aligned);
}
void* available_address(const Broker& b, uint64_t bytes, uint64_t alignment) {
    // The mutex protects every live interval and the uninterrupted reservation.
    // Never replace an emulator/JIT/GPU allocation or an arbitrary address.
    const uintptr_t begin = reinterpret_cast<uintptr_t>(b.arena);
    const uintptr_t end = begin + b.arena_size;
    uintptr_t candidate = (begin + alignment - 1) & ~(alignment - 1);
    while (candidate <= end && bytes <= end - candidate) {
        uintptr_t next = candidate;
        for (const auto& block : b.blocks) if (block.address) {
            const uintptr_t start = reinterpret_cast<uintptr_t>(block.address);
            const uintptr_t finish = start + block.size;
            if (candidate < finish && start < candidate + bytes && finish > next)
                next = finish;
        }
        if (next == candidate) return reinterpret_cast<void*>(candidate);
        candidate = (next + alignment - 1) & ~(alignment - 1);
    }
    return nullptr;
}
int record_allocation(Broker& b, Block& slot, void* address, uint64_t size,
                      uint32_t owner, int fd, uint64_t donation_token,
                      std::chrono::steady_clock::time_point started, void** out) {
    slot = {address, size, owner, fd, donation_token};
    if (donation_token) b.shared_live_bytes += size;
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
    auto& b = broker();
    std::lock_guard guard(b.mutex);
    if (owner >= NEOSWAP_OWNER_COUNT || (kind != NEOSWAP_CPU_DATA && kind != NEOSWAP_CPU_CACHE) ||
        !bytes || !power_of_two(alignment) || alignment > 65536 || bytes > max_block_bytes)
        return reject(b, owner, NEOSWAP_INVALID);
    bool donor_enabled = false;
#if defined(NEOSWAP_DONATION)
    donor_enabled = owner == NEOSWAP_RPCS3 && b.donation_config.capacity_bytes &&
        (b.donation_config.enabled_owner_mask & (1u << owner)) && donation_ready();
#endif
    const bool file_enabled = b.config.capacity_bytes && b.directory >= 0 && b.arena &&
        (b.config.enabled_owner_mask & (1u << owner));
    if (!file_enabled && !donor_enabled)
        return reject(b, owner, NEOSWAP_DISABLED);
    uint64_t minimum = b.config.minimum_allocation_bytes;
#if defined(NEOSWAP_DONATION)
    if (donor_enabled) minimum = b.donation_config.minimum_allocation_bytes;
#endif
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
    for (auto& item : b.blocks) if (!item.address) { slot = &item; break; }
    if (!slot || b.next_name == std::numeric_limits<uint64_t>::max()) return reject(b, owner, NEOSWAP_LIMIT);
    const auto started = std::chrono::steady_clock::now();
#if defined(NEOSWAP_DONATION)
    // Borrow only a verified helper-owned object, entirely locally. Never wait
    // for extension launch/XPC on an emulator thread. Probe remains file-only.
    if (donor_enabled) {
        void* donated = nullptr;
        uint64_t token = 0;
        if (neostation::donation::pool_acquire(rounded, std::max(alignment, page), &donated, &token))
            return record_allocation(b, *slot, donated, rounded, owner, -1, token, started, out);
    }
#endif
    if (!file_enabled) return reject(b, owner, NEOSWAP_DISABLED);
    void* reserved = available_address(b, rounded, alignment > page ? alignment : page);
    if (!reserved) return reject(b, owner, NEOSWAP_QUOTA);
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
    // This interval belongs exclusively to the broker's PROT_NONE arena.
    void* p = fail(b, 3) ? MAP_FAILED : ::mmap(reserved, rounded,
        PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    if (p == MAP_FAILED) {
        const int e = errno; ::close(fd); return reject(b, owner, NEOSWAP_MAPPING, e);
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
        // Atomically restore our reservation. There is never an unmapped gap
        // into which another allocator could insert a foreign mapping.
        if (fail(b, 4) || ::mmap(p, block.size, PROT_NONE,
                MAP_PRIVATE | MAP_ANON | MAP_FIXED, -1, 0) == MAP_FAILED) {
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
            b.stats.last_errno = errno; return NEOSWAP_MAPPING; // retain descriptor/ownership
        }
        }
        const int fd = block.fd;
        if (block.donation_token) b.shared_live_bytes -= block.size;
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
    if (owner >= NEOSWAP_OWNER_COUNT) return 0;
    auto& b = broker();
    if (b.enabled_mask.load(std::memory_order_acquire) & (1u << owner)) return 1;
#if defined(NEOSWAP_DONATION)
    // Do not make a verified donor depend on a successful file-cache arena.
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
        c->minimum_allocation_bytes > max_block_bytes || (c->enabled_owner_mask >> NEOSWAP_OWNER_COUNT))
        return NEOSWAP_INVALID;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    if (b.stats.live_blocks) return NEOSWAP_BUSY;
    if (c->capacity_bytes && (!path || path[0] != '/')) return NEOSWAP_INVALID;
#if defined(NEOSWAP_DONATION)
    // This validated donor policy is independent from disk availability and
    // address reservation. A failed file reconfiguration preserves its old
    // working config while a ready donor can still serve the requested budget.
    b.donation_config = *c;
    b.donation_enabled_mask.store(c->capacity_bytes ? c->enabled_owner_mask : 0u,
                                 std::memory_order_release);
#endif
    int directory = -1;
    void* arena = nullptr;
    size_t arena_size = 0;
    if (c->capacity_bytes) {
        directory = ::open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (directory < 0) return NEOSWAP_STORAGE;
        struct stat st{};
        if (::fstat(directory, &st) || !S_ISDIR(st.st_mode)) { ::close(directory); return NEOSWAP_STORAGE; }
        const long page = ::sysconf(_SC_PAGESIZE);
        if (page <= 0 || !power_of_two(static_cast<uint64_t>(page))) {
            ::close(directory); return NEOSWAP_MAPPING;
        }
        arena_size = (c->capacity_bytes + static_cast<uint64_t>(page) - 1) &
            ~(static_cast<uint64_t>(page) - 1);
        // No bytes are read/written and no backing file is created here.
        arena = fail(b, 6) ? MAP_FAILED : reserve_arena(arena_size);
        if (arena == MAP_FAILED) {
            const int error = errno;
            ::close(directory);
            b.host_stats.reservation_result = NEOSWAP_MAPPING;
            b.host_stats.reservation_errno = error;
            return NEOSWAP_MAPPING; // previous working configuration is retained
        }
    }
    if (b.arena && ::munmap(b.arena, b.arena_size)) {
        const int error = errno;
        if (arena) ::munmap(arena, arena_size);
        if (directory >= 0) ::close(directory);
        b.host_stats.reservation_result = NEOSWAP_MAPPING;
        b.host_stats.reservation_errno = error;
        return NEOSWAP_MAPPING;
    }
    if (b.directory >= 0) ::close(b.directory);
    b.arena = arena; b.arena_size = arena_size;
    b.host_stats.reserved_virtual_bytes = arena_size;
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
    if (owner >= NEOSWAP_OWNER_COUNT) return;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    b.stats.registered_owner_mask |= 1u << owner;
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
