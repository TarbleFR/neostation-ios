// SPDX-License-Identifier: MIT
#pragma once
#include "Store.h"
#include <memory>
#include <string>

// Explicit CPU ownership, not a virtual-memory pager. No signal handlers,
// guest/JIT/GPU pointers, automatic faults or implicit render-thread I/O.
namespace neostation::managed_swap {
enum class Code { ok, missing, busy, pressure, quota, io, corrupt, stopped, invalid, stale };
struct Object { uint64_t session = 0, id = 0; };
struct Config {
    Config();
    storage::Config store;
    // Total mapped-memory envelope, including owned buffers, Store's hard
    // admission limit and bounded snapshot/codec workspace. Not logical size.
    uint64_t resident_bytes = 16ULL << 20;
    uint64_t logical_bytes = 256ULL << 20;
    uint32_t chunk_bytes = 1U << 20;
    uint32_t max_objects = 32;
};
namespace detail { struct State; struct ReadPin; struct WritePin; }
class ReadLease final {
public:
    ReadLease() noexcept = default;
    const uint8_t* data() const noexcept;
    size_t size() const noexcept;
    uint64_t generation() const noexcept;
    explicit operator bool() const noexcept { return bool(pin_); }
private:
    explicit ReadLease(std::shared_ptr<detail::ReadPin>);
    std::shared_ptr<detail::ReadPin> pin_;
    friend class Manager;
};
class WriteLease final {
public:
    WriteLease() noexcept = default;
    ~WriteLease();
    WriteLease(WriteLease&&) noexcept;
    WriteLease& operator=(WriteLease&&) noexcept;
    WriteLease(const WriteLease&) = delete;
    WriteLease& operator=(const WriteLease&) = delete;
    uint8_t* data() noexcept;
    size_t size() const noexcept;
    // The exclusive lease already owns this new generation. Releasing it
    // makes that generation readable/checkpointable; old tokens become stale.
    uint64_t generation() const noexcept;
    explicit operator bool() const noexcept { return bool(pin_); }
private:
    explicit WriteLease(std::shared_ptr<detail::WritePin>);
    std::shared_ptr<detail::WritePin> pin_;
    friend class Manager;
};
struct Result { Code code = Code::ok; int os_error = 0; };
struct ObjectResult : Result { Object object; uint32_t chunks = 0; };
struct ReadResult : Result { ReadLease lease; };
struct WriteResult : Result { WriteLease lease; };
struct ChunkInfo : Result {
    uint64_t generation = 0, persisted_generation = 0;
    size_t bytes = 0;
    bool resident = false, borrowed = false;
};
struct Stats {
    uint64_t logical_bytes = 0, owned_ram_bytes = 0;
    // Tracked mappings: owned + Store raw/warm/loading + checkpoint draft.
    // Codec scratch/encoded worker workspace is conservatively reserved by
    // backend_workspace_bound_bytes, rather than misreported as measured RAM.
    uint64_t resident_mapped_bytes = 0, resident_mapped_peak = 0;
    uint64_t resident_limit_bytes = 0, owned_limit_bytes = 0;
    uint64_t backend_workspace_bound_bytes = 0;
    uint64_t checkpointed_bytes = 0, released_owned_bytes = 0;
    uint64_t restored_bytes = 0, checkpoints = 0, failures = 0;
    uint64_t objects = 0, chunks = 0;
    storage::Stats store;
};
class Manager final {
public:
    // Construction, blocking methods, destruction and close belong on a
    // utility queue. read/write operate on ONE bounded chunk, never the full
    // logical object. Leases remain valid after destroy/close/owner teardown.
    // Utility submissions retry transient Store busy contention for at most
    // 20 ms; persistent pressure/backpressure remains visible to the caller.
    explicit Manager(const std::string& private_directory, Config = {});
    ~Manager();
    Manager(const Manager&) = delete;
    Manager& operator=(const Manager&) = delete;
    ObjectResult create(uint64_t logical_bytes);
    ChunkInfo describe(Object, uint32_t chunk) const;
    // Hot-path lookup: no blocking lock and no file I/O. Busy means the caller
    // must schedule read_chunk on its utility queue, rather than wait here.
    ReadResult try_read_chunk(Object, uint32_t chunk);
    ReadResult read_chunk(Object, uint32_t chunk);
    WriteResult write_chunk(Object, uint32_t chunk, uint64_t expected_generation);
    // Copies a stable chunk, syncs Store, then verifies a real disk read while
    // retaining the original. Only success replaces the immutable snapshot.
    Result checkpoint_chunk(Object, uint32_t chunk, uint64_t expected_generation);
    // Releases the actual owned mapping only for the current verified version.
    // A borrowed or dirty chunk is retained and returns busy.
    Result evict_chunk(Object, uint32_t chunk);
    // Utility queue only. Pressure rejects new write leases/checkpoints and
    // releases only unborrowed, current verified snapshots; dirty data stays.
    void set_pressure(storage::Pressure);
    Code destroy(Object);
    void close();
    Stats snapshot() const;
#ifdef NEOSWAP_STORAGE_TESTING
    void inject(storage::Store::Fault);
    // Simulates allocation failure between successful persistence and readback.
    void inject_checkpoint_exception();
#endif
private:
    std::shared_ptr<detail::State> state_;
};
} // namespace neostation::managed_swap
