// SPDX-License-Identifier: MIT
#include "ManagedSwapABI.h"
#include "ManagedSwap.h"
#include <cerrno>
#include <memory>
#include <new>
#include <stdexcept>
#include <system_error>
#include <utility>

namespace managed = neostation::managed_swap;
namespace storage = neostation::storage;
struct NeoSwapManagedContext {
    managed::Manager manager;
    NeoSwapManagedContext(const char* directory, managed::Config config) : manager(directory, config) {}
};
struct NeoSwapManagedReadLease { managed::ReadLease pin; };
struct NeoSwapManagedWriteLease { managed::WriteLease pin; };
namespace {
#define ASSERT_CODE(c, n) static_assert(static_cast<uint32_t>(managed::Code::n) == c)
ASSERT_CODE(NS_MANAGED_OK, ok); ASSERT_CODE(NS_MANAGED_MISSING, missing);
ASSERT_CODE(NS_MANAGED_BUSY, busy); ASSERT_CODE(NS_MANAGED_PRESSURE, pressure);
ASSERT_CODE(NS_MANAGED_QUOTA, quota); ASSERT_CODE(NS_MANAGED_IO, io);
ASSERT_CODE(NS_MANAGED_CORRUPT, corrupt); ASSERT_CODE(NS_MANAGED_STOPPED, stopped);
ASSERT_CODE(NS_MANAGED_INVALID, invalid); ASSERT_CODE(NS_MANAGED_STALE, stale);
#undef ASSERT_CODE
template<class T> bool valid(const T* value) noexcept {
    return value && value->struct_size >= sizeof(T) && value->abi_version == NEOSWAP_MANAGED_ABI_VERSION;
}
bool valid_error(const NeoSwapManagedError* error) noexcept { return !error || valid(error); }
uint32_t report(NeoSwapManagedError* error, managed::Result result) noexcept {
    const auto code = static_cast<uint32_t>(result.code);
    if (valid(error)) { error->code = code; error->os_error = result.os_error; }
    return code;
}
managed::Result exception() noexcept {
    try { throw; }
    catch (const std::bad_alloc&) { return {managed::Code::pressure, ENOMEM}; }
    catch (const std::invalid_argument&) { return {managed::Code::invalid, EINVAL}; }
    catch (const std::length_error&) { return {managed::Code::invalid, EOVERFLOW}; }
    catch (const std::system_error& error) { return {managed::Code::io, error.code().value()}; }
    catch (...) { return {managed::Code::io, EIO}; }
}
template<class F> uint32_t invoke(NeoSwapManagedError* error, F&& operation) noexcept {
    if (!valid_error(error)) return NS_MANAGED_INVALID;
    try { return report(error, operation()); }
    catch (...) { return report(error, exception()); }
}
managed::Object object(NeoSwapManagedObject value) noexcept { return {value.session, value.id}; }
void clear(NeoSwapManagedReadView* view) noexcept {
    view->data = nullptr; view->byte_count = 0; view->generation = 0; view->lease = nullptr;
}
void clear(NeoSwapManagedWriteView* view) noexcept {
    view->data = nullptr; view->byte_count = 0; view->generation = 0; view->lease = nullptr;
}
NeoSwapManagedConfig public_config(const managed::Config& c) noexcept {
    return {sizeof(NeoSwapManagedConfig), NEOSWAP_MANAGED_ABI_VERSION,
        c.resident_bytes, c.logical_bytes, c.chunk_bytes, c.max_objects,
        c.store.ram_bytes, c.store.warm_bytes, c.store.disk_bytes, c.store.free_disk_floor,
        c.store.max_write_bytes_per_second, c.store.max_blob, c.store.max_entries,
        c.store.max_queue, c.store.compression_budget_us, c.store.prefetch_latency_limit_us,
        c.store.compression ? 1u : 0u};
}
managed::Config native_config(const NeoSwapManagedConfig* c) {
    managed::Config out;
    if (!c) return out;
    out.resident_bytes = c->resident_bytes; out.logical_bytes = c->logical_bytes;
    out.chunk_bytes = c->chunk_bytes; out.max_objects = c->max_objects;
    out.store.ram_bytes = c->store_ram_bytes; out.store.warm_bytes = c->store_warm_bytes;
    out.store.disk_bytes = c->disk_bytes; out.store.free_disk_floor = c->free_disk_floor;
    out.store.max_write_bytes_per_second = c->max_write_bytes_per_second;
    out.store.max_blob = c->store_max_blob; out.store.max_entries = c->store_max_entries;
    out.store.max_queue = c->store_max_queue; out.store.compression_budget_us = c->compression_budget_us;
    out.store.prefetch_latency_limit_us = c->prefetch_latency_limit_us;
    out.store.compression = c->compression == 1;
    return out;
}
uint32_t read(NeoSwapManagedContext* context, NeoSwapManagedObject value, uint32_t chunk,
              NeoSwapManagedReadView* view, NeoSwapManagedError* error, bool hot) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || !valid(view)) return {managed::Code::invalid, EINVAL};
        if (view->lease) return {managed::Code::busy, 0};
        clear(view);
        // Allocate the wrapper before borrowing. All rejection/exception paths
        // retain RAII ownership, and can never strand a pinned native lease.
        auto wrapper = std::make_unique<NeoSwapManagedReadLease>();
        auto result = hot ? context->manager.try_read_chunk(object(value), chunk)
                          : context->manager.read_chunk(object(value), chunk);
        if (result.code != managed::Code::ok) return {result.code, result.os_error};
        wrapper->pin = std::move(result.lease);
        view->data = wrapper->pin.data(); view->byte_count = wrapper->pin.size();
        view->generation = wrapper->pin.generation(); view->lease = wrapper.release();
        return {};
    });
}
NeoSwapManagedStorageStats public_stats(const storage::Stats& in) noexcept {
    NeoSwapManagedStorageStats out{};
#define COPY(n) out.n = in.n
    COPY(logical_bytes); COPY(raw_ram_bytes); COPY(compressed_ram_bytes);
    COPY(pinned_raw_bytes); COPY(loading_reserved_bytes); COPY(disk_only_logical_bytes);
    COPY(stored_payload_bytes); COPY(allocated_file_bytes); COPY(reserved_file_bytes);
    COPY(reusable_file_bytes); COPY(reused_extent_count); COPY(discarded_entries);
    COPY(bytes_read); COPY(bytes_written); COPY(read_calls); COPY(write_calls);
    COPY(evicted_logical_bytes); COPY(restored_logical_bytes); COPY(warm_hits);
    COPY(ram_hits); COPY(disk_hits); COPY(prefetch_used); COPY(prefetch_wasted);
    COPY(prefetch_cancelled); COPY(io_errors); COPY(corruptions); COPY(quota_refusals);
    COPY(backpressure); COPY(pressure_events); COPY(compression_attempts);
    COPY(compression_accepted); COPY(compression_input_bytes); COPY(compression_output_bytes);
    COPY(compression_us); COPY(decompression_us); COPY(worker_scratch_peak);
    COPY(queue_peak); COPY(managed_ram_peak); COPY(read_p50_us); COPY(read_p95_us);
    COPY(read_p99_us); COPY(read_max_us); COPY(write_p95_us); COPY(queue_p95_us);
    COPY(restore_p95_us); COPY(last_errno);
#undef COPY
    out.pressure = static_cast<uint32_t>(in.pressure);
    return out;
}
}

uint32_t NeoSwapManagedDefaultConfig(NeoSwapManagedConfig* config, uint32_t size) noexcept {
    if (!config || size < sizeof(*config)) return NS_MANAGED_INVALID;
    try { *config = public_config(managed::Config{}); return NS_MANAGED_OK; }
    catch (...) { return static_cast<uint32_t>(exception().code); }
}
NeoSwapManagedContext* NeoSwapManagedCreate(const char* directory, const NeoSwapManagedConfig* config,
                                           NeoSwapManagedError* error) noexcept {
    if (!valid_error(error)) return nullptr;
    if (!directory || (config && (!valid(config) || config->compression > 1))) {
        report(error, {managed::Code::invalid, EINVAL}); return nullptr;
    }
    try {
        auto context = std::make_unique<NeoSwapManagedContext>(directory, native_config(config));
        report(error, {}); return context.release();
    } catch (...) { report(error, exception()); return nullptr; }
}
void NeoSwapManagedDestroy(NeoSwapManagedContext* context) noexcept {
    // Manager destruction performs its synchronous stop/join here on utility;
    // detached read/write pins never own the Manager or its I/O worker.
    try { delete context; } catch (...) {}
}
uint32_t NeoSwapManagedCreateObject(NeoSwapManagedContext* context, uint64_t bytes,
    NeoSwapManagedObject* output, uint32_t* chunks, NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || !output || !chunks) return {managed::Code::invalid, EINVAL};
        *output = {}; *chunks = 0;
        const auto result = context->manager.create(bytes);
        if (result.code == managed::Code::ok) {
            *output = {result.object.id, result.object.session}; *chunks = result.chunks;
        }
        return {result.code, result.os_error};
    });
}
uint32_t NeoSwapManagedDescribeChunk(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, NeoSwapManagedChunkInfo* output, NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || !valid(output)) return {managed::Code::invalid, EINVAL};
        *output = {sizeof(*output), NEOSWAP_MANAGED_ABI_VERSION, 0, 0, 0, 0, 0};
        const auto result = context->manager.describe(object(value), chunk);
        if (result.code == managed::Code::ok) {
            output->generation = result.generation; output->persisted_generation = result.persisted_generation;
            output->byte_count = result.bytes; output->resident = result.resident ? 1u : 0u;
            output->borrowed = result.borrowed ? 1u : 0u;
        }
        return {result.code, result.os_error};
    });
}
uint32_t NeoSwapManagedTryRead(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, NeoSwapManagedReadView* output, NeoSwapManagedError* error) noexcept {
    return read(context, value, chunk, output, error, true);
}
uint32_t NeoSwapManagedRead(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, NeoSwapManagedReadView* output, NeoSwapManagedError* error) noexcept {
    return read(context, value, chunk, output, error, false);
}
uint32_t NeoSwapManagedWrite(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, uint64_t generation, NeoSwapManagedWriteView* output, NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || !valid(output)) return {managed::Code::invalid, EINVAL};
        if (output->lease) return {managed::Code::busy, 0};
        clear(output);
        auto wrapper = std::make_unique<NeoSwapManagedWriteLease>();
        auto result = context->manager.write_chunk(object(value), chunk, generation);
        if (result.code != managed::Code::ok) return {result.code, result.os_error};
        wrapper->pin = std::move(result.lease);
        output->data = wrapper->pin.data(); output->byte_count = wrapper->pin.size();
        output->generation = wrapper->pin.generation(); output->lease = wrapper.release();
        return {};
    });
}
uint32_t NeoSwapManagedCheckpoint(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, uint64_t generation, NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        return context ? context->manager.checkpoint_chunk(object(value), chunk, generation)
                       : managed::Result{managed::Code::invalid, EINVAL};
    });
}
uint32_t NeoSwapManagedEvict(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    uint32_t chunk, NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        return context ? context->manager.evict_chunk(object(value), chunk)
                       : managed::Result{managed::Code::invalid, EINVAL};
    });
}
uint32_t NeoSwapManagedRetire(NeoSwapManagedContext* context, NeoSwapManagedObject value,
    NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        return context ? managed::Result{context->manager.destroy(object(value)), 0}
                       : managed::Result{managed::Code::invalid, EINVAL};
    });
}
void NeoSwapManagedReleaseRead(NeoSwapManagedReadView* output) noexcept {
    if (!valid(output) || !output->lease) return;
    auto* lease = output->lease; clear(output);
    try { delete lease; } catch (...) {}
}
void NeoSwapManagedReleaseWrite(NeoSwapManagedWriteView* output) noexcept {
    if (!valid(output) || !output->lease) return;
    auto* lease = output->lease; clear(output);
    try { delete lease; } catch (...) {}
}
uint32_t NeoSwapManagedSnapshot(NeoSwapManagedContext* context, NeoSwapManagedStats* output,
    NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || !valid(output)) return {managed::Code::invalid, EINVAL};
        const auto in = context->manager.snapshot();
        *output = {sizeof(*output), NEOSWAP_MANAGED_ABI_VERSION,
            in.logical_bytes, in.owned_ram_bytes, in.resident_mapped_bytes,
            in.resident_mapped_peak, in.resident_limit_bytes, in.owned_limit_bytes,
            in.backend_workspace_bound_bytes, in.checkpointed_bytes, in.released_owned_bytes,
            in.restored_bytes, in.checkpoints, in.failures, in.objects, in.chunks,
            public_stats(in.store)};
        return {};
    });
}
uint32_t NeoSwapManagedSetPressure(NeoSwapManagedContext* context, uint32_t pressure,
    NeoSwapManagedError* error) noexcept {
    return invoke(error, [&]() -> managed::Result {
        if (!context || pressure > NS_MANAGED_PRESSURE_CRITICAL) return {managed::Code::invalid, EINVAL};
        context->manager.set_pressure(static_cast<storage::Pressure>(pressure));
        return {};
    });
}
#ifdef NEOSWAP_STORAGE_TESTING
uint32_t NeoSwapManagedTestInject(NeoSwapManagedContext* context, uint32_t fault) noexcept {
    return invoke(nullptr, [&]() -> managed::Result {
        if (!context || fault > NS_MANAGED_TEST_CORRUPT) return {managed::Code::invalid, EINVAL};
        context->manager.inject(static_cast<storage::Store::Fault>(fault));
        return {};
    });
}
#endif
