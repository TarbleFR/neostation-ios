// SPDX-License-Identifier: MIT
#pragma once
#include <cstddef>
#include <cstdint>
#include <future>
#include <memory>
#include <string>

// Experimental, explicitly owned immutable CPU blobs only. Not a VM pager.
// Never hand this API a live RPCS3 guest region, JIT code, GPU resource, raw
// allocator pointer, or the only copy of save data. No signal-handler calls.
namespace neostation::storage {
enum class Code { ok, missing, busy, pressure, quota, io, corrupt, stopped, invalid };
enum class Heat { cold, hot };
enum class Pressure { normal, warning, critical };
struct Handle { uint64_t session = 0, id = 0; };

class Bytes final {
public:
    Bytes() noexcept = default;
    explicit Bytes(size_t size);
    ~Bytes();
    Bytes(Bytes&&) noexcept;
    Bytes& operator=(Bytes&&) noexcept;
    Bytes(const Bytes&) = delete;
    Bytes& operator=(const Bytes&) = delete;
    uint8_t* data() noexcept { return data_; } // producer only, before publish
    const uint8_t* data() const noexcept { return data_; }
    size_t size() const noexcept { return size_; }
    size_t mapped_size() const noexcept { return mapped_; }
    bool shrink(size_t size) noexcept;
    bool seal() noexcept; // read-only once published
private:
    uint8_t* data_ = nullptr;
    size_t size_ = 0, mapped_ = 0;
};
struct Lease {
    std::shared_ptr<const Bytes> bytes;
    const uint8_t* data() const noexcept { return bytes ? bytes->data() : nullptr; }
    size_t size() const noexcept { return bytes ? bytes->size() : 0; }
};
struct Result { Code code = Code::ok; int os_error = 0; Lease lease; };
struct Submission {
    Code code = Code::ok;
    Handle handle;
    std::future<Result> completion;
};
struct Config {
    uint64_t ram_bytes = 32ULL << 20;
    uint64_t warm_bytes = 4ULL << 20;
    uint64_t disk_bytes = 256ULL << 20;
    uint64_t free_disk_floor = 512ULL << 20;
    uint32_t max_blob = 1U << 20;
    uint32_t max_entries = 1024, max_queue = 16;
    uint32_t compression_budget_us = 1000;
    uint32_t prefetch_latency_limit_us = 8000;
    uint64_t max_write_bytes_per_second = 16ULL << 20;
    bool compression = true;
};
struct Stats {
    uint64_t logical_bytes = 0, raw_ram_bytes = 0, compressed_ram_bytes = 0;
    uint64_t pinned_raw_bytes = 0, loading_reserved_bytes = 0;
    uint64_t disk_only_logical_bytes = 0, stored_payload_bytes = 0;
    uint64_t allocated_file_bytes = 0, reserved_file_bytes = 0;
    uint64_t reusable_file_bytes = 0, reused_extent_count = 0;
    uint64_t discarded_entries = 0;
    uint64_t bytes_read = 0, bytes_written = 0, read_calls = 0, write_calls = 0;
    uint64_t evicted_logical_bytes = 0, restored_logical_bytes = 0;
    uint64_t warm_hits = 0, ram_hits = 0, disk_hits = 0;
    uint64_t prefetch_used = 0, prefetch_wasted = 0, prefetch_cancelled = 0;
    uint64_t io_errors = 0, corruptions = 0, quota_refusals = 0, backpressure = 0;
    uint64_t pressure_events = 0, compression_attempts = 0, compression_accepted = 0;
    uint64_t compression_input_bytes = 0, compression_output_bytes = 0;
    uint64_t compression_us = 0, decompression_us = 0, worker_scratch_peak = 0;
    uint64_t queue_peak = 0, managed_ram_peak = 0;
    uint64_t read_p50_us = 0, read_p95_us = 0, read_p99_us = 0, read_max_us = 0;
    uint64_t write_p95_us = 0, queue_p95_us = 0, restore_p95_us = 0;
    int last_errno = 0;
    Pressure pressure = Pressure::normal;
};

class Store final {
public:
    // Setup/utility queue only. Session-only private unlinked 0600 cache file.
    explicit Store(const std::string& parent, Config = {});
    ~Store();
    Store(const Store&) = delete;
    Store& operator=(const Store&) = delete;
    // Rejection preserves caller ownership. Admission moves immutable bytes.
    // Disk failures retain the original; a Lease pins data until its release.
    Submission publish(std::unique_ptr<Bytes>& input, Heat = Heat::cold);
    Result try_acquire(Handle);
    Submission request(Handle, bool speculative = false);
    Submission trim();
    Submission barrier();
    Code erase(Handle);
    // Retire ownership without waiting for pending I/O or outstanding leases.
    Code discard(Handle);
    void set_pressure(Pressure) noexcept;
    Stats snapshot() const;
#ifdef NEOSWAP_STORAGE_TESTING
    enum class Fault { none, write_error, sync_error, read_error, short_io, truncate, corrupt };
    void inject(Fault);
#endif
private:
    struct Impl;
    std::unique_ptr<Impl> p_;
};
struct ProcessMetrics {
    uint64_t resident_bytes = 0, footprint_bytes = 0, compressed_accounted_bytes = 0;
    uint64_t process_available_bytes = 0;
    bool resident_valid = false, footprint_valid = false, compressed_valid = false;
    bool process_available_valid = false;
};
ProcessMetrics sample_process() noexcept;
const char* codec_name() noexcept;
} // namespace neostation::storage
