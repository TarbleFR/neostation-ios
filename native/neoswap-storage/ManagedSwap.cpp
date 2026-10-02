// SPDX-License-Identifier: MIT
#include "ManagedSwap.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <limits>
#include <mutex>
#include <stdexcept>
#include <system_error>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>
#include <unistd.h>

namespace neostation::managed_swap {
namespace {
std::atomic<uint64_t> next_session{1};
uint64_t mapped_size(uint64_t bytes) {
    const uint64_t page = static_cast<uint64_t>(::sysconf(_SC_PAGESIZE));
    if (!bytes || bytes > UINT64_MAX - page) throw std::invalid_argument("chunk size");
    return ((bytes + page - 1) / page) * page;
}
Code translate(storage::Code code) {
    switch (code) {
    case storage::Code::ok: return Code::ok;
    case storage::Code::missing: return Code::missing;
    case storage::Code::busy: return Code::busy;
    case storage::Code::pressure: return Code::pressure;
    case storage::Code::quota: return Code::quota;
    case storage::Code::io: return Code::io;
    case storage::Code::corrupt: return Code::corrupt;
    case storage::Code::stopped: return Code::stopped;
    case storage::Code::invalid: return Code::invalid;
    }
    return Code::invalid;
}
Result wait(storage::Submission submission) {
    if (submission.code != storage::Code::ok && !submission.completion.valid())
        return {translate(submission.code), 0};
    const auto result = submission.completion.get();
    return {translate(result.code), result.os_error};
}
template<class Operation>
storage::Submission retry_busy(Operation&& operation) {
    // Store deliberately uses try_lock. A utility caller can tolerate brief
    // worker-lock contention without confusing it with a permanent rejection.
    // No sleep is paid on the normal path; pinned/backpressure refusal remains
    // bounded and is returned to the caller rather than waited on indefinitely.
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(20);
    for (;;) {
        auto submission = operation();
        if (submission.code != storage::Code::busy ||
            std::chrono::steady_clock::now() >= deadline) return submission;
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
}
} // namespace
Config::Config() {
    store.ram_bytes = 4ULL << 20;
    store.warm_bytes = 0;
    store.compression = false;
}
namespace detail {
struct Accounting {
    std::atomic<uint64_t> owned{0}, immutable_pinned{0};
};
struct Owned final {
    storage::Bytes bytes;
    std::shared_ptr<Accounting> accounting;
    Owned(size_t size, std::shared_ptr<Accounting> counters)
        : bytes(size), accounting(std::move(counters)) {
        accounting->owned.fetch_add(bytes.mapped_size());
    }
    ~Owned() {
        const auto mapped = bytes.mapped_size();
        bytes = storage::Bytes{}; // Unmap before another thread can reuse quota.
        accounting->owned.fetch_sub(mapped);
    }
};
struct Chunk {
    size_t bytes = 0;
    uint64_t generation = 1, persisted_generation = 0;
    storage::Handle persisted;
    std::shared_ptr<Owned> owned;
    std::atomic<uint32_t> readers{0}, immutable_readers{0};
    std::atomic<bool> writer{false};
};
struct Record {
    uint64_t logical_bytes = 0;
    std::vector<std::shared_ptr<Chunk>> chunks;
};
struct ReadPin {
    std::shared_ptr<Chunk> chunk;
    std::shared_ptr<Owned> owned;
    storage::Lease immutable;
    std::shared_ptr<Accounting> accounting;
    uint64_t generation = 0;
    ~ReadPin() {
        if (immutable.bytes && chunk->immutable_readers.fetch_sub(1) == 1)
            accounting->immutable_pinned.fetch_sub(immutable.bytes->mapped_size());
        chunk->readers.fetch_sub(1, std::memory_order_release);
    }
};
struct WritePin {
    std::shared_ptr<Chunk> chunk;
    std::shared_ptr<Owned> owned;
    uint64_t generation = 0;
    ~WritePin() { chunk->writer.store(false, std::memory_order_release); }
};
struct State {
    mutable std::mutex mutex;
    Config config;
    const uint64_t session = next_session.fetch_add(1);
    uint64_t next_id = 1, owned_limit = 0, workspace_bound = 0, staging = 0;
    bool stopped = false;
    storage::Pressure pressure = storage::Pressure::normal;
    std::unique_ptr<storage::Store> store;
    std::shared_ptr<Accounting> accounting = std::make_shared<Accounting>();
    std::unordered_map<uint64_t, Record> objects;
    Stats stats;
#ifdef NEOSWAP_STORAGE_TESTING
    bool throw_after_persistence = false;
#endif
    explicit State(const std::string& directory, Config value) : config(value) {
        const uint64_t chunk_mapping = mapped_size(config.chunk_bytes);
        const uint64_t blob_mapping = mapped_size(config.store.max_blob);
        // Store admits up to ram + one max_blob. The second max_blob is the
        // pre-publication checkpoint copy. Compression needs a further encoded
        // blob and at most 1 MiB codec scratch (Store enforces that bound).
        workspace_bound = config.store.ram_bytes + 2 * blob_mapping;
        if (config.store.compression) workspace_bound += blob_mapping + (1ULL << 20);
        if (!config.max_objects || config.max_objects > 4096 ||
            config.chunk_bytes < 65536 || config.chunk_bytes > config.store.max_blob ||
            config.store.max_entries < 2 || !config.logical_bytes ||
            config.logical_bytes > (8ULL << 30) ||
            config.resident_bytes < workspace_bound + chunk_mapping ||
            config.resident_bytes > (2ULL << 30))
            throw std::invalid_argument("managed swap limits");
        owned_limit = config.resident_bytes - workspace_bound;
        objects.reserve(config.max_objects);
        store = std::make_unique<storage::Store>(directory, config.store);
    }
    std::shared_ptr<Chunk> find(Object object, uint32_t index) const {
        if (object.session != session) return {};
        const auto found = objects.find(object.id);
        if (found == objects.end() || index >= found->second.chunks.size()) return {};
        return found->second.chunks[index];
    }
    bool borrowed(const Chunk& chunk) const {
        return chunk.writer.load(std::memory_order_acquire) ||
               chunk.readers.load(std::memory_order_acquire) != 0;
    }
    void peak() {
        const auto backend = store ? store->snapshot() : storage::Stats{};
        const uint64_t resident = accounting->owned.load() + staging +
            (store ? backend.raw_ram_bytes + backend.compressed_ram_bytes + backend.loading_reserved_bytes
                   : accounting->immutable_pinned.load());
        stats.resident_mapped_peak = std::max(stats.resident_mapped_peak, resident);
    }
    std::shared_ptr<Owned> allocate(size_t size) {
        const auto bytes = mapped_size(size);
        const auto current = accounting->owned.load();
        if (current > owned_limit || bytes > owned_limit - current) return {};
        auto out = std::make_shared<Owned>(size, accounting);
        peak();
        return out;
    }
    storage::Result acquire(storage::Handle handle, bool* did_restore = nullptr) {
        if (did_restore) *did_restore = false;
        auto hot = store->try_acquire(handle);
        if (hot.code == storage::Code::ok) return hot;
        const auto before = store->snapshot().restored_logical_bytes;
        auto request = request_chunk(handle);
        if (request.code != storage::Code::ok) return {request.code, 0, {}};
        auto result = request.completion.get();
        if (did_restore && result.code == storage::Code::ok)
            *did_restore = store->snapshot().restored_logical_bytes > before;
        return result;
    }
    storage::Submission request_chunk(storage::Handle handle) {
        return retry_busy([&] { return store->request(handle); });
    }
    storage::Submission publish_chunk(std::unique_ptr<storage::Bytes>& snapshot) {
        return retry_busy([&] { return store->publish(snapshot, storage::Heat::cold); });
    }
    Result initialize(const std::shared_ptr<Chunk>& chunk) {
        if (chunk->owned) return {};
        auto local = allocate(chunk->bytes);
        if (!local) return {Code::quota, 0};
        if (chunk->persisted_generation) {
            bool did_restore = false;
            auto restored = acquire(chunk->persisted, &did_restore);
            if (restored.code != storage::Code::ok)
                return {translate(restored.code), restored.os_error};
            if (restored.lease.size() != chunk->bytes) return {Code::corrupt, 0};
            std::memcpy(local->bytes.data(), restored.lease.data(), chunk->bytes);
            if (did_restore) stats.restored_bytes += chunk->bytes;
        }
        // New objects are lazily zero-filled by anonymous mmap; create itself
        // allocates metadata only and never reports logical capacity as RAM.
        chunk->owned = std::move(local);
        peak();
        return {};
    }
    std::shared_ptr<ReadPin> pin(const std::shared_ptr<Chunk>& chunk,
                                 storage::Lease immutable = {}) {
        auto out = std::make_shared<ReadPin>();
        out->chunk = chunk;
        out->owned = chunk->owned;
        out->immutable = std::move(immutable);
        out->accounting = accounting;
        out->generation = chunk->generation;
        chunk->readers.fetch_add(1);
        if (out->immutable.bytes && chunk->immutable_readers.fetch_add(1) == 0)
            accounting->immutable_pinned.fetch_add(out->immutable.bytes->mapped_size());
        return out;
    }
    void retire(storage::Handle handle) {
        if (!handle.id) return;
        if (store->erase(handle) == storage::Code::busy) (void)store->discard(handle);
    }
};
} // namespace detail

ReadLease::ReadLease(std::shared_ptr<detail::ReadPin> pin) : pin_(std::move(pin)) {}
const uint8_t* ReadLease::data() const noexcept {
    return !pin_ ? nullptr : pin_->owned ? pin_->owned->bytes.data() : pin_->immutable.data();
}
size_t ReadLease::size() const noexcept {
    return !pin_ ? 0 : pin_->owned ? pin_->owned->bytes.size() : pin_->immutable.size();
}
uint64_t ReadLease::generation() const noexcept { return pin_ ? pin_->generation : 0; }
WriteLease::WriteLease(std::shared_ptr<detail::WritePin> pin) : pin_(std::move(pin)) {}
WriteLease::~WriteLease() = default;
WriteLease::WriteLease(WriteLease&&) noexcept = default;
WriteLease& WriteLease::operator=(WriteLease&&) noexcept = default;
uint8_t* WriteLease::data() noexcept { return pin_ ? pin_->owned->bytes.data() : nullptr; }
size_t WriteLease::size() const noexcept { return pin_ ? pin_->owned->bytes.size() : 0; }
uint64_t WriteLease::generation() const noexcept { return pin_ ? pin_->generation : 0; }

Manager::Manager(const std::string& directory, Config config)
    : state_(std::make_shared<detail::State>(directory, config)) {}
Manager::~Manager() { close(); }
ObjectResult Manager::create(uint64_t bytes) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {{Code::stopped, 0}, {}, 0};
    if (!bytes || bytes > state.config.logical_bytes) return {{Code::invalid, 0}, {}, 0};
    const uint64_t count = (bytes + state.config.chunk_bytes - 1) / state.config.chunk_bytes;
    // Keep one Store entry available for an atomic generation replacement.
    if (state.objects.size() >= state.config.max_objects ||
        bytes > state.config.logical_bytes - state.stats.logical_bytes ||
        count > state.config.store.max_entries - 1 - state.stats.chunks)
        return {{Code::quota, 0}, {}, 0};
    detail::Record record;
    record.logical_bytes = bytes;
    record.chunks.reserve(static_cast<size_t>(count));
    uint64_t remaining = bytes;
    for (uint64_t index = 0; index < count; ++index) {
        auto chunk = std::make_shared<detail::Chunk>();
        chunk->bytes = static_cast<size_t>(std::min<uint64_t>(remaining, state.config.chunk_bytes));
        remaining -= chunk->bytes;
        record.chunks.push_back(std::move(chunk));
    }
    const Object object{state.session, state.next_id++};
    state.objects.emplace(object.id, std::move(record));
    state.stats.logical_bytes += bytes;
    state.stats.chunks += count;
    return {{Code::ok, 0}, object, static_cast<uint32_t>(count)};
}
ChunkInfo Manager::describe(Object object, uint32_t index) const {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {{Code::stopped, 0}, 0, 0, 0, false, false};
    auto chunk = state.find(object, index);
    if (!chunk) return {{Code::missing, 0}, 0, 0, 0, false, false};
    const bool resident = bool(chunk->owned) ||
        (chunk->persisted.id && state.store->try_acquire(chunk->persisted).code == storage::Code::ok);
    return {{Code::ok, 0}, chunk->generation, chunk->persisted_generation,
            chunk->bytes, resident, state.borrowed(*chunk)};
}
ReadResult Manager::try_read_chunk(Object object, uint32_t index) {
    auto& state = *state_;
    std::unique_lock lock(state.mutex, std::try_to_lock);
    if (!lock.owns_lock()) return {{Code::busy, 0}, {}};
    if (state.stopped) return {{Code::stopped, 0}, {}};
    auto chunk = state.find(object, index);
    if (!chunk) return {{Code::missing, 0}, {}};
    if (chunk->writer.load(std::memory_order_acquire)) return {{Code::busy, 0}, {}};
    if (chunk->owned) return {{Code::ok, 0}, ReadLease(state.pin(chunk))};
    if (!chunk->persisted.id) return {{Code::busy, 0}, {}};
    auto hot = state.store->try_acquire(chunk->persisted);
    if (hot.code != storage::Code::ok) return {{translate(hot.code), hot.os_error}, {}};
    return {{Code::ok, 0}, ReadLease(state.pin(chunk, std::move(hot.lease)))};
}
ReadResult Manager::read_chunk(Object object, uint32_t index) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {{Code::stopped, 0}, {}};
    auto chunk = state.find(object, index);
    if (!chunk) return {{Code::missing, 0}, {}};
    if (chunk->writer.load(std::memory_order_acquire)) return {{Code::busy, 0}, {}};
    if (chunk->owned) return {{Code::ok, 0}, ReadLease(state.pin(chunk))};
    if (!chunk->persisted.id) {
        const auto result = state.initialize(chunk);
        if (result.code != Code::ok) return {{result.code, result.os_error}, {}};
        return {{Code::ok, 0}, ReadLease(state.pin(chunk))};
    }
    bool did_restore = false;
    auto restored = state.acquire(chunk->persisted, &did_restore);
    if (restored.code != storage::Code::ok) {
        ++state.stats.failures;
        return {{translate(restored.code), restored.os_error}, {}};
    }
    if (restored.lease.size() != chunk->bytes) return {{Code::corrupt, 0}, {}};
    if (did_restore) state.stats.restored_bytes += chunk->bytes;
    auto lease = ReadLease(state.pin(chunk, std::move(restored.lease)));
    state.peak();
    return {{Code::ok, 0}, std::move(lease)};
}
WriteResult Manager::write_chunk(Object object, uint32_t index, uint64_t expected) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {{Code::stopped, 0}, {}};
    auto chunk = state.find(object, index);
    if (!chunk) return {{Code::missing, 0}, {}};
    if (expected != chunk->generation) return {{Code::stale, 0}, {}};
    if (state.borrowed(*chunk)) return {{Code::busy, 0}, {}};
    if (state.pressure != storage::Pressure::normal) return {{Code::pressure, 0}, {}};
    if (chunk->generation == UINT64_MAX) return {{Code::quota, 0}, {}};
    const auto result = state.initialize(chunk);
    if (result.code != Code::ok) return {{result.code, result.os_error}, {}};
    auto pin = std::make_shared<detail::WritePin>();
    pin->chunk = chunk;
    pin->owned = chunk->owned;
    pin->generation = ++chunk->generation;
    chunk->writer.store(true, std::memory_order_release);
    return {{Code::ok, 0}, WriteLease(std::move(pin))};
}
Result Manager::checkpoint_chunk(Object object, uint32_t index, uint64_t expected) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {Code::stopped, 0};
    auto chunk = state.find(object, index);
    if (!chunk) return {Code::missing, 0};
    if (expected != chunk->generation) return {Code::stale, 0};
    if (state.borrowed(*chunk)) return {Code::busy, 0};
    if (chunk->persisted_generation == chunk->generation) return {};
    if (state.pressure != storage::Pressure::normal) return {Code::pressure, 0};
    const auto initialized = state.initialize(chunk);
    if (initialized.code != Code::ok) return initialized;
    // Drop only completed, unborrowed backend copies before admission. A
    // release of a former read pin can then recover promptly, without waiting
    // for Store's periodic maintenance; dirty owned bytes remain untouched.
    const auto trimmed = wait(state.store->trim());
    if (trimmed.code != Code::ok) return trimmed;
    auto snapshot = std::make_unique<storage::Bytes>(chunk->bytes);
    state.staging = snapshot->mapped_size();
    struct StagingReset { uint64_t& bytes; ~StagingReset() { bytes = 0; } } reset{state.staging};
    std::memcpy(snapshot->data(), chunk->owned->bytes.data(), chunk->bytes);
    state.peak();
    auto publication = state.publish_chunk(snapshot);
    state.staging = 0;
    if (publication.code != storage::Code::ok) {
        ++state.stats.failures;
        if (publication.completion.valid()) return wait(std::move(publication));
        return {translate(publication.code), 0};
    }
    const auto candidate = publication.handle;
    struct CandidateRetirement {
        detail::State& state;
        storage::Handle handle;
        bool committed = false;
        ~CandidateRetirement() noexcept {
            if (!committed) {
                ++state.stats.failures;
                // Publication can still be inflight during stack unwinding;
                // retire marks busy handles discarded for deferred collection.
                try { state.retire(handle); } catch (...) {}
            }
        }
    } retirement{state, candidate};
    auto result = wait(std::move(publication));
#ifdef NEOSWAP_STORAGE_TESTING
    if (result.code == Code::ok && std::exchange(state.throw_after_persistence, false))
        throw std::bad_alloc();
#endif
    if (result.code == Code::ok) result = wait(state.store->trim());
    // With no lease on the candidate, trim removes its actual Store copy.
    // request now performs a real disk read, CRC verification and sealing.
    storage::Result verified;
    if (result.code == Code::ok) {
        auto request = state.request_chunk(candidate);
        if (request.code == storage::Code::ok) verified = request.completion.get();
        else verified.code = request.code;
        result = {translate(verified.code), verified.os_error};
        if (result.code == Code::ok && (verified.lease.size() != chunk->bytes ||
            std::memcmp(verified.lease.data(), chunk->owned->bytes.data(), chunk->bytes)))
            result = {Code::corrupt, 0};
    }
    verified.lease.bytes.reset();
    if (result.code != Code::ok) {
        state.peak();
        return result;
    }
    const auto previous = chunk->persisted;
    chunk->persisted = candidate;
    chunk->persisted_generation = chunk->generation;
    retirement.committed = true;
    state.retire(previous);
    ++state.stats.checkpoints;
    state.stats.checkpointed_bytes += chunk->bytes;
    state.peak();
    return {};
}
Result Manager::evict_chunk(Object object, uint32_t index) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return {Code::stopped, 0};
    auto chunk = state.find(object, index);
    if (!chunk) return {Code::missing, 0};
    if (state.borrowed(*chunk) || chunk->persisted_generation != chunk->generation)
        return {Code::busy, 0};
    // Trim is completed before the owned mapping goes away. No incomplete
    // checkpoint, failed write or stale snapshot authorizes an unmap.
    const auto result = wait(state.store->trim());
    if (result.code != Code::ok) return result;
    if (chunk->owned) state.stats.released_owned_bytes += chunk->owned->bytes.mapped_size();
    chunk->owned.reset();
    state.peak();
    return {};
}
void Manager::set_pressure(storage::Pressure pressure) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return;
    state.pressure = pressure;
    state.store->set_pressure(pressure);
    if (pressure == storage::Pressure::normal) return;
    const uint64_t target = pressure == storage::Pressure::critical ? 0 : state.owned_limit / 2;
    for (auto& [id, record] : state.objects) {
        (void)id;
        for (auto& chunk : record.chunks) {
            if (state.accounting->owned.load() <= target) break;
            if (!chunk->owned || state.borrowed(*chunk) ||
                chunk->persisted_generation != chunk->generation) continue;
            state.stats.released_owned_bytes += chunk->owned->bytes.mapped_size();
            chunk->owned.reset();
        }
    }
    // Demand reads are still permitted by Store under pressure; only clean,
    // unpinned backing copies can be dropped by its completed trim.
    (void)wait(state.store->trim());
    state.peak();
}
Code Manager::destroy(Object object) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return Code::stopped;
    if (object.session != state.session) return Code::missing;
    auto found = state.objects.find(object.id);
    if (found == state.objects.end()) return Code::missing;
    for (const auto& chunk : found->second.chunks) state.retire(chunk->persisted);
    state.stats.logical_bytes -= found->second.logical_bytes;
    state.stats.chunks -= found->second.chunks.size();
    state.objects.erase(found);
    // Surviving pins retain only buffers/chunks/counters, not State or Store.
    // Their owned mappings stay charged through Accounting until final release.
    state.peak();
    return Code::ok;
}
void Manager::close() {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (state.stopped) return;
    state.stopped = true;
    state.objects.clear();
    state.stats.logical_bytes = 0;
    state.stats.chunks = 0;
    // All worker I/O and the join happen here, on the caller's utility queue.
    // Leases own detached Bytes, so their later release never joins a worker.
    state.store.reset();
    state.peak();
}
Stats Manager::snapshot() const {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    state.peak();
    Stats out = state.stats;
    out.owned_ram_bytes = state.accounting->owned.load();
    out.resident_limit_bytes = state.config.resident_bytes;
    out.owned_limit_bytes = state.owned_limit;
    out.backend_workspace_bound_bytes = state.workspace_bound;
    out.objects = state.objects.size();
    if (state.store) {
        out.store = state.store->snapshot();
        out.resident_mapped_bytes = out.owned_ram_bytes + out.store.raw_ram_bytes +
            out.store.compressed_ram_bytes + out.store.loading_reserved_bytes + state.staging;
    } else out.resident_mapped_bytes = out.owned_ram_bytes + state.accounting->immutable_pinned.load();
    return out;
}
#ifdef NEOSWAP_STORAGE_TESTING
void Manager::inject(storage::Store::Fault fault) {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (!state.stopped) state.store->inject(fault);
}
void Manager::inject_checkpoint_exception() {
    auto& state = *state_;
    std::lock_guard lock(state.mutex);
    if (!state.stopped) state.throw_after_persistence = true;
}
#endif
} // namespace neostation::managed_swap
