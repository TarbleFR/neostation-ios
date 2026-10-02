// SPDX-License-Identifier: MIT
#include "ManagedSwap.h"
#include <atomic>
#include <chrono>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>
#include <vector>
#include <unistd.h>
using namespace neostation::managed_swap;
#define CHECK(value) do { if (!(value)) { std::cerr << "FAIL " << __LINE__ << ": " #value "\n"; std::abort(); } } while (0)
Result checkpoint(Manager& manager, Object object, uint32_t chunk, uint64_t generation) {
    auto result = manager.checkpoint_chunk(object, chunk, generation);
    if (result.code != Code::ok)
        std::cerr << "checkpoint failure chunk=" << chunk << " generation=" << generation
                  << " code=" << static_cast<int>(result.code) << " errno=" << result.os_error << "\n";
    return result;
}
constexpr uint64_t MiB = 1ULL << 20;
Stats cycle_stats;
neostation::storage::ProcessMetrics process_before, process_after_cold;
uint64_t random_byte(uint64_t& value) { value ^= value << 13; value ^= value >> 7; value ^= value << 17; return value; }
void fill(uint8_t* data, size_t size, uint64_t seed) {
    for (size_t index = 0; index < size; ++index) data[index] = static_cast<uint8_t>(random_byte(seed));
}
bool verify(const ReadLease& lease, uint64_t seed) {
    if (!lease || !lease.size()) return false;
    for (size_t index = 0; index < lease.size(); ++index)
        if (lease.data()[index] != static_cast<uint8_t>(random_byte(seed))) return false;
    return true;
}
Config config() {
    Config out;
    out.store.ram_bytes = 2 * MiB;
    out.store.warm_bytes = 0;
    out.store.disk_bytes = 128 * MiB;
    out.store.free_disk_floor = 0;
    out.store.max_write_bytes_per_second = 0;
    out.store.compression = false;
    out.resident_bytes = 8 * MiB; // Four MiB owned, four MiB backend/workspace.
    out.logical_bytes = 128 * MiB;
    return out;
}
uint64_t write(Manager& manager, Object object, uint32_t chunk, uint64_t seed) {
    auto info = manager.describe(object, chunk);
    CHECK(info.code == Code::ok);
    auto result = manager.write_chunk(object, chunk, info.generation);
    CHECK(result.code == Code::ok && result.lease);
    fill(result.lease.data(), result.lease.size(), seed);
    return result.lease.generation();
}
void test_large_cycle(const std::string& directory) {
    process_before = neostation::storage::sample_process();
    Manager manager(directory, config());
    auto object = manager.create(64 * MiB);
    CHECK(object.code == Code::ok && object.chunks == 64);
    CHECK(manager.snapshot().logical_bytes == 64 * MiB);
    CHECK(manager.snapshot().resident_mapped_bytes == 0);
    CHECK(manager.try_read_chunk(object.object, 0).code == Code::busy);
    for (uint32_t index = 0; index < object.chunks; ++index) {
        const auto generation = write(manager, object.object, index, 1000 + index);
        CHECK(checkpoint(manager, object.object, index, generation).code == Code::ok);
        const auto before = manager.snapshot();
        CHECK(before.owned_ram_bytes == MiB);
        CHECK(before.store.disk_hits == index + 1); // Real verification read.
        CHECK(manager.evict_chunk(object.object, index).code == Code::ok);
        const auto after = manager.snapshot();
        CHECK(after.owned_ram_bytes == 0 && after.resident_mapped_bytes == 0);
        CHECK(after.store.loading_reserved_bytes == 0);
        CHECK(after.resident_mapped_peak <= after.resident_limit_bytes);
    }
    auto stats = manager.snapshot();
    CHECK(stats.checkpointed_bytes == 64 * MiB);
    CHECK(stats.store.stored_payload_bytes == 64 * MiB);
    CHECK(stats.store.disk_only_logical_bytes == 64 * MiB);
    CHECK(stats.store.allocated_file_bytes >= 64 * MiB);
    CHECK(stats.store.bytes_read >= 64 * MiB && stats.store.bytes_written >= 64 * MiB);
    CHECK(stats.released_owned_bytes == 64 * MiB);
    // Every logical chunk is touched and reloaded in shuffled order, with only
    // one bounded lease. No contiguous 64-MiB reconstruction occurs.
    for (uint32_t step = 0; step < object.chunks; ++step) {
        const uint32_t index = (step * 7) % object.chunks;
        auto restored = manager.read_chunk(object.object, index);
        CHECK(restored.code == Code::ok && verify(restored.lease, 1000 + index));
        CHECK(restored.lease.size() == MiB);
        CHECK(manager.evict_chunk(object.object, index).code == Code::busy);
        CHECK(manager.write_chunk(object.object, index, restored.lease.generation()).code == Code::busy);
        restored.lease = {};
        CHECK(manager.evict_chunk(object.object, index).code == Code::ok);
    }
    stats = manager.snapshot();
    CHECK(stats.store.disk_hits == object.chunks * 2);
    CHECK(stats.restored_bytes == 64 * MiB);
    CHECK(stats.resident_mapped_bytes == 0);
    CHECK(stats.store.reserved_file_bytes <= config().store.disk_bytes);
    cycle_stats = stats;
    process_after_cold = neostation::storage::sample_process();
}
void test_versions_and_pins(const std::string& directory) {
    Manager manager(directory, config());
    auto object = manager.create(MiB);
    CHECK(object.code == Code::ok);
    auto zero = manager.read_chunk(object.object, 0);
    CHECK(zero.code == Code::ok && zero.lease.generation() == 1);
    for (size_t index = 0; index < zero.lease.size(); ++index) CHECK(zero.lease.data()[index] == 0);
    auto second_reader = zero.lease;
    zero.lease = {};
    CHECK(manager.write_chunk(object.object, 0, 1).code == Code::busy);
    second_reader = {};
    const uint64_t first = write(manager, object.object, 0, 45);
    CHECK(first == 2);
    CHECK(manager.checkpoint_chunk(object.object, 0, first).code == Code::ok);
    CHECK(manager.evict_chunk(object.object, 0).code == Code::ok);
    const uint64_t second = write(manager, object.object, 0, 46);
    CHECK(second == 3);
    CHECK(manager.describe(object.object, 0).persisted_generation == first);
    CHECK(manager.checkpoint_chunk(object.object, 0, first).code == Code::stale);
    CHECK(manager.write_chunk(object.object, 0, first).code == Code::stale);
    CHECK(manager.evict_chunk(object.object, 0).code == Code::busy);
    CHECK(manager.checkpoint_chunk(object.object, 0, second).code == Code::ok);
    CHECK(manager.snapshot().store.logical_bytes == MiB); // Previous version retired.
    CHECK(manager.evict_chunk(object.object, 0).code == Code::ok);
    auto restored = manager.read_chunk(object.object, 0);
    CHECK(restored.code == Code::ok && verify(restored.lease, 46));
    CHECK(restored.lease.generation() == second);
    restored.lease = {};
    auto writer = manager.write_chunk(object.object, 0, second);
    CHECK(writer.code == Code::ok);
    CHECK(manager.read_chunk(object.object, 0).code == Code::busy);
    CHECK(manager.try_read_chunk(object.object, 0).code == Code::busy);
    CHECK(manager.checkpoint_chunk(object.object, 0, writer.lease.generation()).code == Code::busy);
    CHECK(manager.evict_chunk(object.object, 0).code == Code::busy);
    writer.lease = {};
    CHECK(manager.read_chunk({object.object.session + 1, object.object.id}, 0).code == Code::missing);
    CHECK(manager.read_chunk(object.object, 1).code == Code::missing);
}
void test_failures(const std::string& directory) {
    for (const auto fault : {neostation::storage::Store::Fault::write_error,
                             neostation::storage::Store::Fault::sync_error,
                             neostation::storage::Store::Fault::read_error,
                             neostation::storage::Store::Fault::corrupt,
                             neostation::storage::Store::Fault::truncate}) {
        Manager manager(directory, config());
        auto object = manager.create(MiB);
        const auto first = write(manager, object.object, 0, 98);
        CHECK(manager.checkpoint_chunk(object.object, 0, first).code == Code::ok);
        const auto second = write(manager, object.object, 0, 99);
        manager.inject(fault);
        const auto result = manager.checkpoint_chunk(object.object, 0, second);
        CHECK(result.code == Code::io || result.code == Code::corrupt);
        CHECK(result.os_error == (fault == neostation::storage::Store::Fault::write_error ? ENOSPC :
                                  fault == neostation::storage::Store::Fault::corrupt ? EILSEQ : EIO));
        CHECK(manager.describe(object.object, 0).persisted_generation == first);
        CHECK(manager.describe(object.object, 0).generation == second);
        CHECK(manager.snapshot().owned_ram_bytes == MiB);
        CHECK(manager.evict_chunk(object.object, 0).code == Code::busy);
        auto current = manager.read_chunk(object.object, 0);
        CHECK(current.code == Code::ok && verify(current.lease, 99));
        current.lease = {};
        CHECK(manager.checkpoint_chunk(object.object, 0, second).code == Code::ok);
        CHECK(manager.evict_chunk(object.object, 0).code == Code::ok);
        manager.inject(neostation::storage::Store::Fault::read_error);
        auto failed_restore = manager.read_chunk(object.object, 0);
        CHECK(failed_restore.code == Code::io && !failed_restore.lease);
        CHECK(failed_restore.os_error == EIO);
        CHECK(manager.describe(object.object, 0).persisted_generation == second);
        auto recovered = manager.read_chunk(object.object, 0);
        CHECK(recovered.code == Code::ok && verify(recovered.lease, 99));
    }
    auto small = config();
    small.store.disk_bytes = MiB;
    Manager quota(directory, small);
    auto object = quota.create(MiB);
    const auto generation = write(quota, object.object, 0, 60);
    CHECK(quota.checkpoint_chunk(object.object, 0, generation).code == Code::io);
    CHECK(quota.snapshot().store.reserved_file_bytes == 0);
    CHECK(quota.snapshot().owned_ram_bytes == MiB);
    CHECK(verify(quota.read_chunk(object.object, 0).lease, 60));
    // A thrown queue-allocation error after persistence must retire the
    // unpublished candidate, preserving both the draft and previous version.
    auto tight = config();
    tight.store.max_entries = 2; // One chunk plus one generation replacement.
    Manager exception(directory, tight);
    auto owned = exception.create(MiB);
    const auto first = write(exception, owned.object, 0, 61);
    CHECK(exception.checkpoint_chunk(owned.object, 0, first).code == Code::ok);
    const auto second = write(exception, owned.object, 0, 62);
    exception.inject_checkpoint_exception();
    bool threw = false;
    try { (void)exception.checkpoint_chunk(owned.object, 0, second); }
    catch (const std::bad_alloc&) { threw = true; }
    CHECK(threw);
    CHECK(exception.describe(owned.object, 0).persisted_generation == first);
    CHECK(exception.snapshot().store.logical_bytes == MiB);
    CHECK(exception.snapshot().owned_ram_bytes == MiB);
    CHECK(verify(exception.read_chunk(owned.object, 0).lease, 62));
    CHECK(exception.checkpoint_chunk(owned.object, 0, second).code == Code::ok);
    CHECK(exception.snapshot().store.logical_bytes == MiB);
    CHECK(exception.evict_chunk(owned.object, 0).code == Code::ok);
    CHECK(verify(exception.read_chunk(owned.object, 0).lease, 62));
}
void test_retirement_and_shutdown(const std::string& directory) {
    auto limited = config();
    limited.resident_bytes = 5 * MiB; // 1 MiB owned remains after backend envelope.
    Manager manager(directory, limited);
    auto first = manager.create(MiB);
    write(manager, first.object, 0, 81);
    auto survivor = manager.read_chunk(first.object, 0);
    CHECK(manager.destroy(first.object) == Code::ok);
    CHECK(manager.snapshot().owned_ram_bytes == MiB);
    auto replacement = manager.create(MiB);
    CHECK(replacement.code == Code::ok);
    CHECK(manager.write_chunk(replacement.object, 0, 1).code == Code::quota);
    CHECK(verify(survivor.lease, 81));
    survivor.lease = {};
    CHECK(manager.snapshot().owned_ram_bytes == 0);
    CHECK(manager.write_chunk(replacement.object, 0, 1).code == Code::ok);
    ReadLease detached_read;
    WriteLease detached_write;
    {
        Manager transient(directory, config());
        auto read_object = transient.create(MiB);
        const auto generation = write(transient, read_object.object, 0, 82);
        CHECK(transient.checkpoint_chunk(read_object.object, 0, generation).code == Code::ok);
        CHECK(transient.evict_chunk(read_object.object, 0).code == Code::ok);
        detached_read = transient.read_chunk(read_object.object, 0).lease;
        auto write_object = transient.create(MiB);
        detached_write = transient.write_chunk(write_object.object, 0, 1).lease;
        CHECK(detached_write);
        fill(detached_write.data(), detached_write.size(), 83);
        transient.close();
        CHECK(transient.snapshot().resident_mapped_bytes == 2 * MiB);
        CHECK(transient.create(MiB).code == Code::stopped);
        CHECK(transient.read_chunk(read_object.object, 0).code == Code::stopped);
        CHECK(transient.try_read_chunk(read_object.object, 0).code == Code::stopped);
        CHECK(transient.evict_chunk(read_object.object, 0).code == Code::stopped);
        CHECK(verify(detached_read, 82));
    }
    CHECK(verify(detached_read, 82));
    CHECK(detached_write && detached_write.data()[0] != 0);
    // Lease teardown does not retain State/Store and needs no worker join.
    std::thread releaser([read = std::move(detached_read), writer = std::move(detached_write)]() mutable {
        read = {};
        writer = {};
    });
    releaser.join();
}
void test_bounds(const std::string& directory) {
    Manager manager(directory, config());
    CHECK(manager.create(0).code == Code::invalid);
    CHECK(manager.create(config().logical_bytes + 1).code == Code::invalid);
    auto small = config();
    small.store.max_entries = 3;
    small.max_objects = 2;
    Manager bounded(directory, small);
    auto a = bounded.create(MiB);
    auto b = bounded.create(MiB);
    CHECK(a.code == Code::ok && b.code == Code::ok);
    CHECK(bounded.create(1).code == Code::quota);
    CHECK(bounded.destroy(a.object) == Code::ok);
    CHECK(bounded.destroy(a.object) == Code::missing);
    CHECK(bounded.create(1).code == Code::ok);
    bool rejected = false;
    try { auto bad = config(); bad.resident_bytes = 4 * MiB; Manager invalid(directory, bad); }
    catch (const std::invalid_argument&) { rejected = true; }
    CHECK(rejected);
    auto tail = manager.create(MiB + 17);
    CHECK(tail.code == Code::ok && tail.chunks == 2);
    const auto generation = write(manager, tail.object, 1, 650);
    CHECK(manager.snapshot().owned_ram_bytes == static_cast<uint64_t>(::sysconf(_SC_PAGESIZE)));
    CHECK(manager.checkpoint_chunk(tail.object, 1, generation).code == Code::ok);
    CHECK(manager.evict_chunk(tail.object, 1).code == Code::ok);
    auto restored = manager.read_chunk(tail.object, 1);
    CHECK(restored.code == Code::ok && restored.lease.size() == 17 && verify(restored.lease, 650));
}
void test_pressure(const std::string& directory) {
    Manager manager(directory, config());
    auto object = manager.create(3 * MiB);
    const auto clean = write(manager, object.object, 0, 71);
    const auto pinned = write(manager, object.object, 1, 72);
    const auto dirty = write(manager, object.object, 2, 73);
    CHECK(manager.checkpoint_chunk(object.object, 0, clean).code == Code::ok);
    CHECK(manager.checkpoint_chunk(object.object, 1, pinned).code == Code::ok);
    auto reader = manager.read_chunk(object.object, 1);
    CHECK(reader.code == Code::ok);
    manager.set_pressure(neostation::storage::Pressure::critical);
    CHECK(manager.snapshot().owned_ram_bytes == 2 * MiB); // Dirty and pinned retained.
    CHECK(!manager.describe(object.object, 0).resident);
    CHECK(verify(reader.lease, 72));
    CHECK(manager.write_chunk(object.object, 2, dirty).code == Code::pressure);
    CHECK(manager.checkpoint_chunk(object.object, 2, dirty).code == Code::pressure);
    CHECK(manager.evict_chunk(object.object, 2).code == Code::busy);
    CHECK(verify(manager.read_chunk(object.object, 2).lease, 73));
    auto clean_read = manager.read_chunk(object.object, 0);
    CHECK(clean_read.code == Code::ok && verify(clean_read.lease, 71));
    clean_read.lease = {};
    reader.lease = {};
    manager.set_pressure(neostation::storage::Pressure::critical);
    CHECK(manager.snapshot().owned_ram_bytes == MiB);
    manager.set_pressure(neostation::storage::Pressure::normal);
    CHECK(manager.checkpoint_chunk(object.object, 2, dirty).code == Code::ok);
    CHECK(manager.evict_chunk(object.object, 2).code == Code::ok);
    CHECK(manager.snapshot().resident_mapped_bytes == 0);
}
void test_compression_workspace(const std::string& directory) {
    auto compressed = config();
    compressed.store.compression = true;
    compressed.store.compression_budget_us = 1000000;
    compressed.store.warm_bytes = MiB;
    compressed.resident_bytes = 16 * MiB;
    Manager manager(directory, compressed);
    auto object = manager.create(MiB);
    auto writer = manager.write_chunk(object.object, 0, 1);
    CHECK(writer.code == Code::ok);
    std::memset(writer.lease.data(), 0x5a, writer.lease.size());
    const auto generation = writer.lease.generation();
    writer.lease = {};
    CHECK(manager.checkpoint_chunk(object.object, 0, generation).code == Code::ok);
    CHECK(manager.snapshot().store.compression_accepted == 1);
    CHECK(manager.snapshot().backend_workspace_bound_bytes == 6 * MiB);
    CHECK(manager.evict_chunk(object.object, 0).code == Code::ok);
    auto read = manager.read_chunk(object.object, 0);
    CHECK(read.code == Code::ok);
    for (size_t index = 0; index < read.lease.size(); ++index) CHECK(read.lease.data()[index] == 0x5a);
    // Reading hot backing again must not invent a second disk restoration.
    const auto before = manager.snapshot().restored_bytes;
    auto hot = manager.read_chunk(object.object, 0);
    CHECK(hot.code == Code::ok && manager.snapshot().restored_bytes == before);
    CHECK(manager.snapshot().resident_mapped_peak <= manager.snapshot().resident_limit_bytes);
}
void test_bounded_backpressure(const std::string& directory) {
    Manager manager(directory, config());
    auto object = manager.create(4 * MiB);
    std::vector<ReadLease> pins;
    for (uint32_t index = 0; index < 3; ++index) {
        const auto generation = write(manager, object.object, index, 800 + index);
        CHECK(checkpoint(manager, object.object, index, generation).code == Code::ok);
        CHECK(manager.evict_chunk(object.object, index).code == Code::ok);
        auto restored = manager.read_chunk(object.object, index);
        CHECK(restored.code == Code::ok && verify(restored.lease, 800 + index));
        pins.push_back(std::move(restored.lease));
    }
    CHECK(manager.snapshot().store.pinned_raw_bytes == 3 * MiB);
    const auto generation = write(manager, object.object, 3, 803);
    const auto start = std::chrono::steady_clock::now();
    const auto blocked = manager.checkpoint_chunk(object.object, 3, generation);
    const auto elapsed = std::chrono::steady_clock::now() - start;
    CHECK(blocked.code == Code::busy);
    CHECK(elapsed >= std::chrono::milliseconds(10));
    CHECK(elapsed < std::chrono::seconds(1));
    CHECK(manager.snapshot().owned_ram_bytes == MiB);
    CHECK(manager.describe(object.object, 3).persisted_generation == 0);
    CHECK(verify(manager.read_chunk(object.object, 3).lease, 803));
    pins[0] = {};
    CHECK(checkpoint(manager, object.object, 3, generation).code == Code::ok);
    CHECK(manager.evict_chunk(object.object, 3).code == Code::ok);
    CHECK(verify(pins[1], 801) && verify(pins[2], 802));
}
int main(int argc, char** argv) {
    CHECK(argc == 2);
    std::filesystem::create_directories(argv[1]);
    test_large_cycle(argv[1]);
    test_versions_and_pins(argv[1]);
    test_failures(argv[1]);
    test_retirement_and_shutdown(argv[1]);
    test_bounds(argv[1]);
    test_pressure(argv[1]);
    test_compression_workspace(argv[1]);
    test_bounded_backpressure(argv[1]);
    std::cout << std::boolalpha << "{\"schemaVersion\":1,\"passed\":true,\"logicalTouchedBytes\":" << cycle_stats.logical_bytes
              << ",\"byteIdentityVerified\":true,\"ramStorageRamCycleVerified\":true,\"managedMappedPeakBytes\":" << cycle_stats.resident_mapped_peak
              << ",\"managedMappedLimitBytes\":" << cycle_stats.resident_limit_bytes
              << ",\"backendWorkspaceBoundBytes\":" << cycle_stats.backend_workspace_bound_bytes
              << ",\"releasedOwnedBytes\":" << cycle_stats.released_owned_bytes
              << ",\"restoredBytes\":" << cycle_stats.restored_bytes
              << ",\"diskReadBytes\":" << cycle_stats.store.bytes_read
              << ",\"diskWriteBytes\":" << cycle_stats.store.bytes_written
              << ",\"diskAllocatedBytes\":" << cycle_stats.store.allocated_file_bytes
              << ",\"residentAfterEvictionBytes\":" << cycle_stats.resident_mapped_bytes
              << ",\"faultCases\":{\"write\":true,\"sync\":true,\"read\":true,\"corrupt\":true,\"truncate\":true,\"quota\":true,\"allocationException\":true}"
              << ",\"leaseAfterClose\":true,\"pressurePreservesDirtyAndPinned\":true"
              << ",\"boundedBackpressureRetryVerified\":true"
              << ",\"processBefore\":{\"residentValid\":" << process_before.resident_valid
              << ",\"residentBytes\":" << process_before.resident_bytes
              << ",\"footprintValid\":" << process_before.footprint_valid
              << ",\"footprintBytes\":" << process_before.footprint_bytes << "}"
              << ",\"processAfterCold\":{\"residentValid\":" << process_after_cold.resident_valid
              << ",\"residentBytes\":" << process_after_cold.resident_bytes
              << ",\"footprintValid\":" << process_after_cold.footprint_valid
              << ",\"footprintBytes\":" << process_after_cold.footprint_bytes << "}}\n";
}
