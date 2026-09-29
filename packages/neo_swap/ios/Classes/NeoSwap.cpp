// Original NeoStation implementation. See docs/neoswap-v1.md for its scope.
#include "NeoSwap.h"
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
};
struct Broker {
    std::mutex mutex;
    std::array<Block, max_blocks> blocks{};
    NeoSwapConfig config{};
    NeoSwapStats stats{};
    int directory = -1;
    uint64_t next_name = 1;
    std::atomic<uint32_t> enabled_mask{0}, live_count{0};
    std::array<std::atomic<uint64_t>, NEOSWAP_OWNER_COUNT> owner_bytes{};
#ifdef NEOSWAP_TESTING
    int failure = 0;
#endif
    ~Broker() {
        for (auto& b : blocks) {
            if (b.address) { ::munmap(b.address, b.size); ::close(b.fd); }
        }
        if (directory >= 0) ::close(directory);
    }
};
Broker& broker() { static Broker b; return b; }
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
    if (owner < NEOSWAP_OWNER_COUNT) ++b.stats.owners[owner].rejection_count;
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
void* map_aligned(int fd, size_t bytes, size_t alignment, size_t page) {
    if (alignment <= page) return ::mmap(nullptr, bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    const size_t span = bytes + alignment;
    void* reserved = ::mmap(nullptr, span, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (reserved == MAP_FAILED) return MAP_FAILED;
    const uintptr_t start = reinterpret_cast<uintptr_t>(reserved);
    const uintptr_t aligned = (start + alignment - 1) & ~(alignment - 1);
    // MAP_FIXED replaces ONLY our own still-live PROT_NONE reservation.
    void* result = ::mmap(reinterpret_cast<void*>(aligned), bytes,
                          PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    if (result == MAP_FAILED) {
        const int e = errno; ::munmap(reserved, span); errno = e; return MAP_FAILED;
    }
    const size_t prefix = aligned - start, suffix = span - prefix - bytes;
    if (prefix) ::munmap(reserved, prefix);
    if (suffix) ::munmap(reinterpret_cast<void*>(aligned + bytes), suffix);
    return result;
}
int allocate(uint32_t owner, uint32_t kind, uint64_t bytes, uint64_t alignment, void** out) {
    if (!out) return NEOSWAP_INVALID;
    *out = nullptr;
    auto& b = broker();
    std::lock_guard guard(b.mutex);
    if (owner >= NEOSWAP_OWNER_COUNT || (kind != NEOSWAP_CPU_DATA && kind != NEOSWAP_CPU_CACHE) ||
        !bytes || !power_of_two(alignment) || alignment > 65536 || bytes > max_block_bytes)
        return reject(b, owner, NEOSWAP_INVALID);
    if (!b.config.capacity_bytes || b.directory < 0 || !(b.config.enabled_owner_mask & (1u << owner)))
        return reject(b, owner, NEOSWAP_DISABLED);
    if (bytes < b.config.minimum_allocation_bytes) return reject(b, owner, NEOSWAP_TOO_SMALL);
    const long page_long = ::sysconf(_SC_PAGESIZE);
    if (page_long <= 0 || !power_of_two(static_cast<uint64_t>(page_long)))
        return reject(b, owner, NEOSWAP_MAPPING, EINVAL);
    const auto page = static_cast<uint64_t>(page_long);
    const uint64_t rounded = (bytes + page - 1) & ~(page - 1);
    if (rounded > b.config.capacity_bytes - b.stats.live_bytes) return reject(b, owner, NEOSWAP_QUOTA);
    Block* slot = nullptr;
    for (auto& item : b.blocks) if (!item.address) { slot = &item; break; }
    if (!slot || b.next_name == std::numeric_limits<uint64_t>::max()) return reject(b, owner, NEOSWAP_LIMIT);
    struct statvfs space{};
    if (::fstatvfs(b.directory, &space) || !space.f_frsize) return reject(b, owner, NEOSWAP_STORAGE, errno);
    const uint64_t free_bytes = space.f_bavail > UINT64_MAX / space.f_frsize
        ? UINT64_MAX : static_cast<uint64_t>(space.f_bavail) * space.f_frsize;
    if (free_bytes < rounded || free_bytes - rounded < b.config.minimum_free_bytes)
        return reject(b, owner, NEOSWAP_STORAGE, ENOSPC);
    const auto started = std::chrono::steady_clock::now();
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
    void* p = fail(b, 3) ? MAP_FAILED : map_aligned(fd, rounded, alignment, page);
    if (p == MAP_FAILED) {
        const int e = errno; ::close(fd); return reject(b, owner, NEOSWAP_MAPPING, e);
    }
    *slot = {p, rounded, owner, fd};
    b.stats.live_bytes += rounded; ++b.stats.live_blocks; ++b.stats.allocation_count;
    if (b.stats.live_bytes > b.stats.peak_bytes) b.stats.peak_bytes = b.stats.live_bytes;
    auto& o = b.stats.owners[owner]; o.live_bytes += rounded; ++o.allocation_count;
    if (o.live_bytes > o.peak_bytes) o.peak_bytes = o.live_bytes;
    b.owner_bytes[owner].store(o.live_bytes, std::memory_order_relaxed);
    const auto elapsed = static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - started).count());
    b.stats.allocation_time_us += elapsed;
    if (elapsed > b.stats.max_allocation_time_us) b.stats.max_allocation_time_us = elapsed;
    b.live_count.store(static_cast<uint32_t>(b.stats.live_blocks), std::memory_order_release);
    *out = p;
    return NEOSWAP_OK;
}
int release(void* p) {
    if (!p) return NEOSWAP_NOT_OWNED;
    auto& b = broker();
    if (!b.live_count.load(std::memory_order_acquire)) return NEOSWAP_NOT_OWNED;
    std::lock_guard guard(b.mutex);
    for (auto& block : b.blocks) if (block.address == p) {
        if (fail(b, 4) || ::munmap(p, block.size)) {
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_MAPPING;
            b.stats.last_errno = errno; return NEOSWAP_MAPPING; // retain descriptor/ownership
        }
        const int fd = block.fd;
        b.stats.live_bytes -= block.size; --b.stats.live_blocks;
        b.stats.owners[block.owner].live_bytes -= block.size;
        b.owner_bytes[block.owner].store(b.stats.owners[block.owner].live_bytes, std::memory_order_relaxed);
        block = Block{};
        b.live_count.store(static_cast<uint32_t>(b.stats.live_blocks), std::memory_order_release);
        // No retry of close(): its descriptor may already have been recycled.
        if (::close(fd)) { ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno; }
        return NEOSWAP_OK;
    }
    return NEOSWAP_NOT_OWNED;
}
int sync(void* p) {
    auto& b = broker(); std::lock_guard guard(b.mutex);
    for (const auto& block : b.blocks) if (p && block.address == p) {
        if (fail(b, 5) || ::msync(p, block.size, MS_SYNC)) {
            ++b.stats.io_errors; b.stats.last_result = NEOSWAP_IO; b.stats.last_errno = errno;
            return NEOSWAP_IO;
        }
        return NEOSWAP_OK;
    }
    return NEOSWAP_NOT_OWNED;
}
int enabled(uint32_t owner) {
    return owner < NEOSWAP_OWNER_COUNT && (broker().enabled_mask.load(std::memory_order_acquire) & (1u << owner));
}
const NeoSwapAPI api{sizeof(NeoSwapAPI), NEOSWAP_ABI, allocate, release, sync, enabled};
}
extern "C" const NeoSwapAPI* NeoSwap_GetAPI(uint32_t version) {
    return version == NEOSWAP_ABI ? &api : nullptr;
}
extern "C" int NeoSwap_Configure(const char* path, const NeoSwapConfig* c) {
    if (!c || c->struct_size != sizeof(*c) || c->abi_version != NEOSWAP_ABI || c->reserved ||
        c->capacity_bytes > 4 * 1024 * MiB || !c->minimum_allocation_bytes ||
        c->minimum_allocation_bytes > max_block_bytes || (c->enabled_owner_mask >> NEOSWAP_OWNER_COUNT))
        return NEOSWAP_INVALID;
    auto& b = broker(); std::lock_guard guard(b.mutex);
    if (b.stats.live_blocks) return NEOSWAP_BUSY;
    int directory = -1;
    if (c->capacity_bytes) {
        if (!path || path[0] != '/') return NEOSWAP_INVALID;
        directory = ::open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW);
        if (directory < 0) return NEOSWAP_STORAGE;
        struct stat st{};
        if (::fstat(directory, &st) || !S_ISDIR(st.st_mode)) { ::close(directory); return NEOSWAP_STORAGE; }
    }
    if (b.directory >= 0) ::close(b.directory);
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
    out->allocated_disk_bytes = 0;
    for (const auto& block : b.blocks) if (block.address) {
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
