// SPDX-License-Identifier: MIT
import Foundation
import NeoSwapManaged

// This executes the production C interface from Swift on a utility queue.
// It is a native file/ownership proof, not a physical iPhone gameplay test.
func check(_ result: UInt32) { precondition(result == 0) }
DispatchQueue(label: "neostation.managed.swift.proof", qos: .utility).sync {
    var config = NeoSwapManagedConfig()
    check(NeoSwapManagedDefaultConfig(&config, UInt32(MemoryLayout<NeoSwapManagedConfig>.size)))
    config.chunk_bytes = 65536
    config.store_max_blob = 65536
    config.store_ram_bytes = 131072
    config.store_warm_bytes = 0
    config.compression = 0
    config.max_write_bytes_per_second = 0
    config.free_disk_floor = 0
    var error = NeoSwapManagedError()
    error.struct_size = UInt32(MemoryLayout<NeoSwapManagedError>.size)
    error.abi_version = UInt32(NEOSWAP_MANAGED_ABI_VERSION)
    let context = CommandLine.arguments[1].withCString {
        NeoSwapManagedCreate($0, &config, &error)
    }
    precondition(context != nil)
    var object = NeoSwapManagedObject()
    var chunks: UInt32 = 0
    check(NeoSwapManagedCreateObject(context, 65536, &object, &chunks, &error))
    precondition(chunks == 1)
    var info = NeoSwapManagedChunkInfo()
    info.struct_size = UInt32(MemoryLayout<NeoSwapManagedChunkInfo>.size)
    info.abi_version = UInt32(NEOSWAP_MANAGED_ABI_VERSION)
    check(NeoSwapManagedDescribeChunk(context, object, 0, &info, &error))
    var write = NeoSwapManagedWriteView()
    write.struct_size = UInt32(MemoryLayout<NeoSwapManagedWriteView>.size)
    write.abi_version = UInt32(NEOSWAP_MANAGED_ABI_VERSION)
    check(NeoSwapManagedWrite(context, object, 0, info.generation, &write, &error))
    for index in 0..<Int(write.byte_count) {
        write.data![index] = UInt8(truncatingIfNeeded: index * 13 + 11)
    }
    let generation = write.generation
    NeoSwapManagedReleaseWrite(&write)
    check(NeoSwapManagedCheckpoint(context, object, 0, generation, &error))
    check(NeoSwapManagedEvict(context, object, 0, &error))
    var read = NeoSwapManagedReadView()
    read.struct_size = UInt32(MemoryLayout<NeoSwapManagedReadView>.size)
    read.abi_version = UInt32(NEOSWAP_MANAGED_ABI_VERSION)
    check(NeoSwapManagedRead(context, object, 0, &read, &error))
    NeoSwapManagedDestroy(context)
    precondition(read.byte_count == 65536)
    for index in 0..<Int(read.byte_count) {
        precondition(read.data![index] == UInt8(truncatingIfNeeded: index * 13 + 11))
    }
    NeoSwapManagedReleaseRead(&read)
    print("{\"passed\":true,\"swiftABIExecuted\":true,\"restoredContentVerified\":true,\"leaseAfterContextDestroy\":true}")
}
