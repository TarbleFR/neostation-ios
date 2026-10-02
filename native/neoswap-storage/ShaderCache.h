// SPDX-License-Identifier: MIT
#pragma once
#include "Store.h"
#include "StorageABI.h"
#include <array>
#include <atomic>
#include <map>
#include <mutex>
namespace neostation::storage {
using ShaderKey = std::array<uint8_t, 32>;
struct ShaderStats {
    uint64_t lookups=0, hits=0, misses=0, publications=0, publish_rejections=0;
    uint64_t restore_requests=0, restore_failures=0, write_failures=0;
    uint64_t source_compiles=0, cached_module_rejections=0, released_cpu_copy_bytes=0;
    uint64_t invalidations=0, admission_copy_bytes=0, deduplicated=0, tiny_refusals=0;
    uint64_t entries=0, session=0;
    Stats store{};
};
// Core calls never wait for this cache lock. Maintenance belongs to a utility queue.
class ShaderCache final {
public:
    ShaderCache(const std::string& directory, uint64_t generation, Config config);
    Result acquire(const ShaderKey& key);
    Code publish(const ShaderKey&, const uint32_t*, size_t bytes);
    void prefetch(const ShaderKey&);
    void invalidate(const ShaderKey&);
    void event(uint32_t kind, uint64_t bytes) noexcept;
    void pressure(Pressure value) noexcept;
    void maintain();
    ShaderStats snapshot();
    uint64_t generation() const noexcept { return generation_; }
    bool accepting() const noexcept { return !paused_.load() && !poisoned_.load(); }
    void pause(bool value) noexcept { paused_.store(value); }
#ifdef NEOSWAP_STORAGE_TESTING
    Store& test_store() { return store_; }
#endif
private:
    struct Record {
        Handle handle{};
        std::future<Result> write, read;
        uint64_t stamp=0;
        bool failed=false;
    };
    bool poll(Record& record, bool release_read);
    void reclaim_failed();
    Store store_;
    const uint64_t generation_;
    const size_t limit_, max_blob_;
    std::mutex mutex_;
    std::map<ShaderKey, Record> records_;
    uint64_t clock_=0;
    ShaderStats stats_{};
    std::atomic<bool> paused_{false}, poisoned_{false};
    std::atomic<Pressure> pressure_{Pressure::normal};
    std::atomic<uint64_t> source_compiles_{0}, rejected_modules_{0}, released_bytes_{0};
};
bool valid_spirv(const void*, size_t) noexcept;
}
