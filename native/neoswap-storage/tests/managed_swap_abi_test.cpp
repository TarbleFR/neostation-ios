// SPDX-License-Identifier: MIT
#include "ManagedSwapABI.h"
#include "StorageABI.h"
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <thread>
#include <unistd.h>

static_assert(NEOSWAP_STORAGE_ABI == 1 && NEOSWAP_STORAGE_KEY_BYTES == 32);
static_assert(NS_STORAGE_OK == 0 && NS_STORAGE_INVALID == 4);
static_assert(NEOSWAP_MANAGED_ABI_VERSION == 1);
static_assert(sizeof(NeoSwapManagedObject) == 16);
static_assert(sizeof(NeoSwapManagedError) == 16);
static_assert(sizeof(NeoSwapManagedConfig::compression) == sizeof(uint32_t));
namespace {
constexpr uint64_t MiB = 1ULL << 20;
#define CHECK(expression) do { if (!(expression)) throw std::runtime_error("line " + std::to_string(__LINE__) + ": " #expression); } while (false)
template<class T> T output() {
    T out{}; out.struct_size = sizeof(T); out.abi_version = NEOSWAP_MANAGED_ABI_VERSION; return out;
}
template<class T, void (*Release)(T*)> struct View {
    T value = output<T>();
    View() = default;
    View(const View&) = delete;
    View& operator=(const View&) = delete;
    ~View() { Release(&value); }
    void release() { Release(&value); }
};
using Read = View<NeoSwapManagedReadView, NeoSwapManagedReleaseRead>;
using Write = View<NeoSwapManagedWriteView, NeoSwapManagedReleaseWrite>;
using Context = std::unique_ptr<NeoSwapManagedContext, decltype(&NeoSwapManagedDestroy)>;
NeoSwapManagedConfig config() {
    NeoSwapManagedConfig out{};
    CHECK(NeoSwapManagedDefaultConfig(&out, sizeof(out)) == NS_MANAGED_OK);
    out.resident_bytes = 12 * MiB; out.logical_bytes = 64 * MiB;
    out.store_ram_bytes = 4 * MiB; out.store_warm_bytes = 0;
    out.disk_bytes = 128 * MiB; out.free_disk_floor = 0;
    out.max_write_bytes_per_second = 256 * MiB;
    out.store_max_entries = 128; out.max_objects = 8; out.compression = 0;
    return out;
}
Context create(const std::string& directory, const NeoSwapManagedConfig& cfg) {
    auto error = output<NeoSwapManagedError>();
    Context context(NeoSwapManagedCreate(directory.c_str(), &cfg, &error), NeoSwapManagedDestroy);
    CHECK(context && error.code == NS_MANAGED_OK && error.os_error == 0);
    return context;
}
NeoSwapManagedObject object(NeoSwapManagedContext* context, uint64_t size, uint32_t count) {
    NeoSwapManagedObject out{}; uint32_t chunks = 0;
    auto error = output<NeoSwapManagedError>();
    CHECK(NeoSwapManagedCreateObject(context, size, &out, &chunks, &error) == NS_MANAGED_OK);
    CHECK(out.id && out.session && chunks == count && error.code == NS_MANAGED_OK);
    return out;
}
NeoSwapManagedChunkInfo describe(NeoSwapManagedContext* context, NeoSwapManagedObject obj, uint32_t chunk) {
    auto out = output<NeoSwapManagedChunkInfo>();
    CHECK(NeoSwapManagedDescribeChunk(context, obj, chunk, &out, nullptr) == NS_MANAGED_OK);
    return out;
}
NeoSwapManagedStats stats(NeoSwapManagedContext* context) {
    auto out = output<NeoSwapManagedStats>();
    CHECK(NeoSwapManagedSnapshot(context, &out, nullptr) == NS_MANAGED_OK);
    return out;
}
uint8_t byte(uint64_t index, uint32_t seed) {
    return static_cast<uint8_t>((index * 31) ^ (index >> 11) ^ (seed * 67));
}
void fill(Write& write, uint32_t seed) {
    CHECK(write.value.data && write.value.lease);
    for (uint64_t i = 0; i < write.value.byte_count; ++i) write.value.data[i] = byte(i, seed);
}
void verify(const Read& read, uint32_t seed, uint64_t size = MiB) {
    CHECK(read.value.data && read.value.lease && read.value.byte_count == size);
    for (uint64_t i = 0; i < size; ++i) CHECK(read.value.data[i] == byte(i, seed));
}
void empty(const NeoSwapManagedReadView& view) { CHECK(!view.lease && !view.data && !view.byte_count && !view.generation); }
void empty(const NeoSwapManagedWriteView& view) { CHECK(!view.lease && !view.data && !view.byte_count && !view.generation); }

NeoSwapManagedStats round_trip(const std::string& directory) {
    const auto cfg = config(); auto context = create(directory, cfg);
    auto obj = object(context.get(), 64 * MiB, 64);
    CHECK(stats(context.get()).owned_ram_bytes == 0);
    auto error = output<NeoSwapManagedError>();
    for (uint32_t chunk = 0; chunk < 64; ++chunk) {
        const auto initial = describe(context.get(), obj, chunk);
        CHECK(initial.generation == 1 && initial.byte_count == MiB && !initial.resident);
        Write write;
        CHECK(NeoSwapManagedWrite(context.get(), obj, chunk, initial.generation, &write.value, &error) == NS_MANAGED_OK);
        CHECK(write.value.generation == 2 && write.value.byte_count == MiB);
        fill(write, chunk);
        if (chunk == 0) {
            Read busy;
            CHECK(NeoSwapManagedTryRead(context.get(), obj, chunk, &busy.value, &error) == NS_MANAGED_BUSY);
            empty(busy.value);
            CHECK(NeoSwapManagedCheckpoint(context.get(), obj, chunk, 2, &error) == NS_MANAGED_BUSY);
            CHECK(NeoSwapManagedEvict(context.get(), obj, chunk, &error) == NS_MANAGED_BUSY);
        }
        write.release(); empty(write.value);
        CHECK(NeoSwapManagedCheckpoint(context.get(), obj, chunk, 1, &error) == NS_MANAGED_STALE);
        CHECK(error.code == NS_MANAGED_STALE);
        const auto checkpoint = NeoSwapManagedCheckpoint(context.get(), obj, chunk, 2, &error);
        if (checkpoint != NS_MANAGED_OK) throw std::runtime_error("checkpoint chunk " + std::to_string(chunk) +
            " code " + std::to_string(checkpoint) + " os_error " + std::to_string(error.os_error));
        CHECK(describe(context.get(), obj, chunk).persisted_generation == 2);
        CHECK(NeoSwapManagedEvict(context.get(), obj, chunk, &error) == NS_MANAGED_OK);
        CHECK(!describe(context.get(), obj, chunk).resident);
    }
    const auto cold = stats(context.get());
    CHECK(cold.logical_bytes == 64 * MiB && cold.owned_ram_bytes == 0);
    CHECK(cold.checkpointed_bytes == 64 * MiB && cold.released_owned_bytes == 64 * MiB);
    CHECK(cold.store.allocated_file_bytes >= 64 * MiB && cold.store.allocated_file_bytes <= cfg.disk_bytes);
    CHECK(cold.resident_mapped_peak <= cold.resident_limit_bytes);
    NeoSwapManagedObject refused{}; uint32_t ignored = 0;
    CHECK(NeoSwapManagedCreateObject(context.get(), MiB, &refused, &ignored, &error) == NS_MANAGED_QUOTA);
    CHECK(error.code == NS_MANAGED_QUOTA && !refused.id && !ignored);
    for (uint32_t chunk = 0; chunk < 64; ++chunk) {
        Read read;
        const auto before = stats(context.get());
        CHECK(NeoSwapManagedTryRead(context.get(), obj, chunk, &read.value, &error) == NS_MANAGED_BUSY);
        const auto after = stats(context.get());
        CHECK(after.store.bytes_read == before.store.bytes_read && after.store.read_calls == before.store.read_calls);
        empty(read.value);
        CHECK(NeoSwapManagedRead(context.get(), obj, chunk, &read.value, &error) == NS_MANAGED_OK);
        CHECK(read.value.generation == 2); verify(read, chunk);
        // Never overwrite an outstanding opaque lease.
        auto* pin = read.value.lease;
        CHECK(NeoSwapManagedRead(context.get(), obj, chunk, &read.value, &error) == NS_MANAGED_BUSY);
        CHECK(read.value.lease == pin); verify(read, chunk);
        CHECK(NeoSwapManagedEvict(context.get(), obj, chunk, &error) == NS_MANAGED_BUSY);
        read.release(); empty(read.value);
        CHECK(NeoSwapManagedEvict(context.get(), obj, chunk, &error) == NS_MANAGED_OK);
    }
    CHECK(stats(context.get()).restored_bytes == 64 * MiB);
    Write mutation;
    CHECK(NeoSwapManagedWrite(context.get(), obj, 0, 2, &mutation.value, &error) == NS_MANAGED_OK);
    CHECK(mutation.value.generation == 3); fill(mutation, 77); mutation.release();
    Write stale;
    CHECK(NeoSwapManagedWrite(context.get(), obj, 0, 2, &stale.value, &error) == NS_MANAGED_STALE);
    CHECK(error.code == NS_MANAGED_STALE); empty(stale.value);
    CHECK(NeoSwapManagedEvict(context.get(), obj, 0, &error) == NS_MANAGED_BUSY);
    CHECK(NeoSwapManagedCheckpoint(context.get(), obj, 0, 3, &error) == NS_MANAGED_OK);
    CHECK(NeoSwapManagedEvict(context.get(), obj, 0, &error) == NS_MANAGED_OK);
    Read changed;
    CHECK(NeoSwapManagedRead(context.get(), obj, 0, &changed.value, &error) == NS_MANAGED_OK);
    CHECK(changed.value.generation == 3); verify(changed, 77); changed.release();
    const auto final = stats(context.get());
    CHECK(final.resident_mapped_bytes <= final.resident_limit_bytes);
    CHECK(NeoSwapManagedRetire(context.get(), obj, &error) == NS_MANAGED_OK);
    CHECK(NeoSwapManagedRead(context.get(), obj, 0, &changed.value, &error) == NS_MANAGED_MISSING);
    return final;
}
void arguments_and_sessions(const std::string& directory) {
    auto cfg = config(); auto error = output<NeoSwapManagedError>();
    CHECK(NeoSwapManagedDefaultConfig(nullptr, sizeof(cfg)) == NS_MANAGED_INVALID);
    CHECK(NeoSwapManagedDefaultConfig(&cfg, sizeof(cfg) - 1) == NS_MANAGED_INVALID);
    CHECK(!NeoSwapManagedCreate(nullptr, &cfg, &error) && error.code == NS_MANAGED_INVALID);
    CHECK(!NeoSwapManagedCreate("relative", &cfg, &error) && error.code == NS_MANAGED_INVALID);
    CHECK(!NeoSwapManagedCreate((directory + "/absent").c_str(), &cfg, &error));
    CHECK(error.code == NS_MANAGED_IO && error.os_error == ENOENT);
    auto bad = cfg; bad.abi_version += 1;
    CHECK(!NeoSwapManagedCreate(directory.c_str(), &bad, &error) && error.code == NS_MANAGED_INVALID);
    bad = cfg; bad.struct_size -= 1;
    CHECK(!NeoSwapManagedCreate(directory.c_str(), &bad, &error) && error.code == NS_MANAGED_INVALID);
    bad = cfg; bad.compression = 2;
    CHECK(!NeoSwapManagedCreate(directory.c_str(), &bad, &error) && error.code == NS_MANAGED_INVALID);
    bad = cfg; bad.resident_bytes = 1;
    CHECK(!NeoSwapManagedCreate(directory.c_str(), &bad, &error));
    CHECK(error.code == NS_MANAGED_INVALID && error.os_error == EINVAL);
    auto first = create(directory, cfg); auto second = create(directory, cfg);
    const auto obj = object(first.get(), MiB, 1);
    const auto other = object(second.get(), MiB, 1);
    CHECK(obj.session != other.session);
    Read read;
    CHECK(NeoSwapManagedRead(second.get(), obj, 0, &read.value, &error) == NS_MANAGED_MISSING);
    CHECK(NeoSwapManagedRetire(second.get(), obj, &error) == NS_MANAGED_MISSING);
    CHECK(NeoSwapManagedRead(nullptr, obj, 0, &read.value, &error) == NS_MANAGED_INVALID);
    CHECK(NeoSwapManagedRead(first.get(), obj, 0, nullptr, &error) == NS_MANAGED_INVALID);
    read.value.struct_size = 0;
    CHECK(NeoSwapManagedRead(first.get(), obj, 0, &read.value, &error) == NS_MANAGED_INVALID);
    read.value = output<NeoSwapManagedReadView>(); read.value.abi_version += 1;
    CHECK(NeoSwapManagedRead(first.get(), obj, 0, &read.value, &error) == NS_MANAGED_INVALID);
    read.value = output<NeoSwapManagedReadView>();
    CHECK(NeoSwapManagedRead(first.get(), obj, UINT32_MAX, &read.value, &error) == NS_MANAGED_MISSING);
    NeoSwapManagedObject result{}; uint32_t count = 0;
    CHECK(NeoSwapManagedCreateObject(first.get(), 0, &result, &count, &error) == NS_MANAGED_INVALID);
    CHECK(NeoSwapManagedCreateObject(first.get(), MiB, nullptr, &count, &error) == NS_MANAGED_INVALID);
    CHECK(NeoSwapManagedCreateObject(first.get(), MiB, &result, nullptr, &error) == NS_MANAGED_INVALID);
    auto malformed = output<NeoSwapManagedError>(); malformed.struct_size = 0;
    CHECK(NeoSwapManagedCreateObject(first.get(), MiB, &result, &count, &malformed) == NS_MANAGED_INVALID);
    CHECK(stats(first.get()).objects == 1);
    CHECK(NeoSwapManagedSetPressure(first.get(), 99, &error) == NS_MANAGED_INVALID);
    Write blocked;
    CHECK(NeoSwapManagedSetPressure(first.get(), NS_MANAGED_PRESSURE_CRITICAL, &error) == NS_MANAGED_OK);
    CHECK(NeoSwapManagedWrite(first.get(), obj, 0, 1, &blocked.value, &error) == NS_MANAGED_PRESSURE);
    CHECK(error.code == NS_MANAGED_PRESSURE); empty(blocked.value);
    CHECK(NeoSwapManagedSetPressure(first.get(), NS_MANAGED_PRESSURE_NORMAL, &error) == NS_MANAGED_OK);
}
void detached_leases(const std::string& directory) {
    auto context = create(directory, config());
    const auto obj = object(context.get(), 2 * MiB, 2);
    Write initial;
    CHECK(NeoSwapManagedWrite(context.get(), obj, 0, 1, &initial.value, nullptr) == NS_MANAGED_OK);
    fill(initial, 11); initial.release();
    CHECK(NeoSwapManagedCheckpoint(context.get(), obj, 0, 2, nullptr) == NS_MANAGED_OK);
    CHECK(NeoSwapManagedEvict(context.get(), obj, 0, nullptr) == NS_MANAGED_OK);
    Read read; Write write;
    CHECK(NeoSwapManagedRead(context.get(), obj, 0, &read.value, nullptr) == NS_MANAGED_OK);
    CHECK(NeoSwapManagedWrite(context.get(), obj, 1, 1, &write.value, nullptr) == NS_MANAGED_OK);
    fill(write, 12);
    CHECK(NeoSwapManagedRetire(context.get(), obj, nullptr) == NS_MANAGED_OK);
    CHECK(stats(context.get()).objects == 0 && stats(context.get()).owned_ram_bytes == MiB);
    verify(read, 11);
    auto* detached = context.release();
    std::thread utility([detached] { NeoSwapManagedDestroy(detached); });
    utility.join();
    verify(read, 11);
    CHECK(write.value.data && write.value.byte_count == MiB && write.value.lease);
    for (uint64_t i = 0; i < MiB; ++i) CHECK(write.value.data[i] == byte(i, 12));
    write.value.data[0] ^= 1; // The detached exclusive mapping is still valid.
    read.release(); write.release(); empty(read.value); empty(write.value);
    NeoSwapManagedDestroy(nullptr);
}
#ifdef NEOSWAP_STORAGE_TESTING
void native_errors(const std::string& directory) {
    for (uint32_t fault : {NS_MANAGED_TEST_WRITE_ERROR, NS_MANAGED_TEST_SYNC_ERROR,
                           NS_MANAGED_TEST_READ_ERROR, NS_MANAGED_TEST_CORRUPT}) {
        auto context = create(directory, config()); const auto obj = object(context.get(), MiB, 1);
        Write write;
        CHECK(NeoSwapManagedWrite(context.get(), obj, 0, 1, &write.value, nullptr) == NS_MANAGED_OK);
        fill(write, 21); write.release();
        CHECK(NeoSwapManagedTestInject(context.get(), fault) == NS_MANAGED_OK);
        auto error = output<NeoSwapManagedError>();
        const auto code = NeoSwapManagedCheckpoint(context.get(), obj, 0, 2, &error);
        CHECK(code == (fault == NS_MANAGED_TEST_CORRUPT ? NS_MANAGED_CORRUPT : NS_MANAGED_IO));
        CHECK(error.code == code && error.os_error != 0);
        if (fault == NS_MANAGED_TEST_WRITE_ERROR) CHECK(error.os_error == ENOSPC);
        if (fault == NS_MANAGED_TEST_READ_ERROR || fault == NS_MANAGED_TEST_SYNC_ERROR) CHECK(error.os_error == EIO);
        if (fault == NS_MANAGED_TEST_CORRUPT) CHECK(error.os_error == EILSEQ);
        CHECK(describe(context.get(), obj, 0).persisted_generation == 0);
        CHECK(NeoSwapManagedEvict(context.get(), obj, 0, &error) == NS_MANAGED_BUSY);
        Read retained;
        CHECK(NeoSwapManagedTryRead(context.get(), obj, 0, &retained.value, &error) == NS_MANAGED_OK);
        verify(retained, 21); retained.release();
        CHECK(NeoSwapManagedTestInject(context.get(), 999) == NS_MANAGED_INVALID);
        CHECK(NeoSwapManagedTestInject(nullptr, NS_MANAGED_TEST_NONE) == NS_MANAGED_INVALID);
    }
}
#endif
}
int main() {
    char path[] = "/tmp/neoswap-managed-abi-XXXXXX";
    char* directory = ::mkdtemp(path);
    if (!directory) return 1;
    try {
        const auto measured = round_trip(directory);
        arguments_and_sessions(directory); detached_leases(directory);
#ifdef NEOSWAP_STORAGE_TESTING
        native_errors(directory);
#endif
        CHECK(::rmdir(directory) == 0);
        std::cout << "{\"passed\":true,\"cABIExecuted\":true,\"contentVerified\":true,"
            "\"leaseAfterContextDestroy\":true,\"staleGenerationRejected\":true,"
            "\"invalidArgumentsRejected\":true,\"logicalBytes\":" << 64 * MiB <<
            ",\"checkpointedBytes\":" << measured.checkpointed_bytes <<
            ",\"restoredBytes\":" << measured.restored_bytes <<
            ",\"residentMappedPeak\":" << measured.resident_mapped_peak <<
            ",\"residentLimitBytes\":" << measured.resident_limit_bytes << "}\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n'; (void)::rmdir(directory); return 1;
    }
}
