// Experimental macOS proof only; never compiled into NeoStation or its donor.
#pragma once
#import <Metal/Metal.h>
#include <memory>
#include <vector>

// Included after the IPC probe's require/evidence helpers. Every mapping stays
// alive until the GPU command completes and all Metal objects have retired.
static NSDictionary* runMetalDonationProbe(NeoSwapDonorSession* session, uint64_t target) {
  evidence[@"stage"] = @"metal_device";
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  require(device != nil, "Metal device unavailable; no GPU donation proof can be claimed on this runner");
  const auto snapshot = [session snapshot];
  require(snapshot.state == NeoSwapDonorStateActive && snapshot.capacityBytes == target,
          "Metal probe requires a fully verified live donor");
  // Declared before the strong Metal array: buffers retire before their backing
  // mappings on every completed success/failure path.
  std::vector<std::unique_ptr<neostation::donation::Block>> mappings;
  NSDictionary* report;
  @autoreleasepool {
  __attribute__((objc_precise_lifetime)) NSMutableArray<id<MTLBuffer>>* buffers = [NSMutableArray new];
  uint64_t imported = 0;
  neostation::donation::Footprint before, after;
  require(bool(neostation::donation::footprint(before)), "Metal host baseline ledger unavailable");
  for (uint64_t index = 0; index < snapshot.verifiedChunkCount; ++index) {
    evidence[@"stage"] = @"metal_import_verified_chunk";
    const auto bytes = [session chunkCapacityBytes:index];
    require(bytes && bytes % vm_page_size == 0 && bytes <= device.maxBufferLength &&
            imported <= target && bytes <= target - imported, "Invalid Metal chunk extent or device buffer limit");
    mach_port_t right = [session copyMemoryEntryForChunk:index];
    require(right != MACH_PORT_NULL, "Metal chunk has no authenticated memory entry");
    auto mapping = std::make_unique<neostation::donation::Block>();
    const auto mapped = neostation::donation::Block::map_borrowed(right, bytes, *mapping);
    const auto released = mach_port_deallocate(mach_task_self(), right);
    require(bool(mapped) && released == KERN_SUCCESS, "Metal chunk map/right retirement failed");
    id<MTLBuffer> buffer = [device newBufferWithBytesNoCopy:mapping->data() length:bytes
        options:MTLResourceStorageModeShared deallocator:nil];
    require(buffer != nil && buffer.contents == mapping->data() && buffer.length == bytes,
            "Metal refused the exact donated mapping without a copy");
    mappings.push_back(std::move(mapping));
    [buffers addObject:buffer];
    imported += bytes;
  }
  require(imported == target, "Metal imports did not cover the requested verified target");
  evidence[@"metalImportedBytes"] = @(imported);
  evidence[@"metalBuffers"] = @(buffers.count);
  evidence[@"stage"] = @"metal_gpu_write_and_readback";
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLCommandBuffer> command = [queue commandBuffer];
  id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
  id<MTLBuffer> readback = [device newBufferWithLength:vm_page_size options:MTLResourceStorageModeShared];
  require(queue && command && blit && readback, "Metal command/readback allocation failed");
  for (id<MTLBuffer> buffer in buffers) [blit fillBuffer:buffer range:NSMakeRange(0, buffer.length) value:0x3c];
  [blit copyFromBuffer:buffers.lastObject sourceOffset:buffers.lastObject.length - vm_page_size
             toBuffer:readback destinationOffset:0 size:vm_page_size];
  [blit endEncoding];
  dispatch_semaphore_t finished = dispatch_semaphore_create(0);
  [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
    (void)completed; dispatch_semaphore_signal(finished);
  }];
  [command commit];
  // require() exits the probe process on timeout without unwinding the live
  // mappings. Never unmap memory still referenced by an unfinished GPU command.
  require(dispatch_semaphore_wait(finished, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC)) == 0,
          "Metal command timeout; process retirement preserves GPU mapping lifetime");
  if (command.error) evidence[@"metalError"] = command.error.description;
  require(command.status == MTLCommandBufferStatusCompleted && !command.error, "Metal command failed");
  for (const auto& mapping : mappings) {
    const auto* bytes = static_cast<const unsigned char*>(mapping->data());
    for (size_t offset = 0; offset < mapping->size(); offset += vm_page_size)
      require(bytes[offset] == 0x3c, "GPU writes did not reach the actual donated pages");
    require(bytes[mapping->size() - 1] == 0x3c, "GPU last-byte write mismatch");
  }
  const auto* readbackBytes = static_cast<const unsigned char*>(readback.contents);
  for (size_t offset = 0; offset < vm_page_size; ++offset)
    require(readbackBytes[offset] == 0x3c, "GPU readback mismatch");
  require(bool(neostation::donation::footprint(after)), "Metal host final ledger unavailable");
  const auto nonvolatile = after.nonvolatile > before.nonvolatile ? after.nonvolatile - before.nonvolatile : 0;
  const auto footprint = after.physical > before.physical ? after.physical - before.physical : 0;
  evidence[@"metalHostNonvolatileDeltaBytes"] = @(nonvolatile);
  evidence[@"metalHostFootprintDeltaBytes"] = @(footprint);
  require(nonvolatile < MiB && footprint < 64 * MiB,
          "Metal imports charged substantial memory to the host; donor ownership alone does not prove a useful GPU donation");
  // The GPU has completed; retire buffers explicitly before the VM mappings.
  [buffers removeAllObjects];
  command = nil; blit = nil; queue = nil; readback = nil;
  report = @{@"passed":@YES, @"device":device.name, @"importedBytes":@(imported),
           @"gpuWrittenBytes":@(imported), @"bufferCount":@(snapshot.verifiedChunkCount),
           @"gpuToCpuAliasVerified":@YES, @"gpuReadbackVerified":@YES,
           @"hostNonvolatileDeltaBytes":@(nonvolatile), @"hostFootprintDeltaBytes":@(footprint),
           @"realRPCS3GameplayValidated":@NO, @"realIPhoneValidated":@NO};
  } // All autoreleased command/buffer references retire before the mappings.
  mappings.clear();
  return report;
}
