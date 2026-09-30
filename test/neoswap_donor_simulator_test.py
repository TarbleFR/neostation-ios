#!/usr/bin/env python3
"""Real iOS 18 Simulator two-donor, multi-chunk and NeoSwap ABI 1 proof.

No mocked Foundation, fake child PID, entitlement inference, or skipped runtime
failure. Creates and removes only its own app/extension and simulator device.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DONATION = ROOT / 'native/neoswap-donation'
HOST = ROOT / 'packages/neo_swap/ios/Classes'
BUNDLE = 'com.neogamelab.neostation.neoswap-simulator-proof'
LOGS: list[str] = []
sys.path.insert(0, str(ROOT / 'build-utils'))
from configure_neoswap_donor import DONOR_CONTRACTS, REQUIRED_DONOR_ENTITLEMENTS
from embed_rpcs3_host_entitlements import embedded_entitlements, require_entitlements

PROBE_HELPERS = ('NeoSwapDonor.appex',)
PROBE_DONOR_BYTES = 32 * 1024**2

HARNESS = r'''
#import <UIKit/UIKit.h>
#import "NeoSwapDonorIPC.h"
#include "Broker.h"
#include "Pool.h"
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include <algorithm>
#include <atomic>
#include <cstring>
#include <functional>
#include <vector>
#include <unistd.h>

namespace {
using namespace neostation::donation;
constexpr uint64_t MiB = 1024 * 1024;
constexpr uint64_t epoch = 1;
constexpr uint64_t donorTarget = 32 * MiB;
constexpr uint64_t chunkMaximum = 16 * MiB;
constexpr uint64_t campaignTarget = 2 * donorTarget;
std::atomic<bool> completed{false};
struct HeldLoan {
  void* address;
  uint64_t bytes;
  NSUInteger donor;
  unsigned char pattern;
};
NSString* reportPath() {
  NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [documents stringByAppendingPathComponent:@"donation-simulator.json"];
}
void finish(NSDictionary* report) {
  if (completed.exchange(true)) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:reportPath() atomically:YES];
    NSLog(@"NEOSWAP_SIMULATOR_PROOF %@", report);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
  });
}
void fail(NSString* stage, NSString* detail, NSDictionary* diagnostics) {
  finish(@{@"schema":@2, @"passed":@NO, @"stage":stage, @"technicalError":detail,
           @"diagnostics":diagnostics ?: @{}, @"realIPhoneValidated":@NO,
           @"physicalIphoneValidated":@NO});
}
NSString* ownedHelper() {
  NSArray* entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:NSBundle.mainBundle.builtInPlugInsURL
                                               includingPropertiesForKeys:nil options:0 error:nil];
  NSString* found = nil;
  NSString* identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".neoswapdonor"];
  NSDictionary* expectedService = @{@"ServiceType":@"Application", @"_MultipleInstances":@YES, @"_ProcessType":@"App"};
  for (NSURL* entry in entries) {
    if (![entry.pathExtension isEqual:@"appex"]) continue;
    NSBundle* bundle = [NSBundle bundleWithURL:entry];
    NSDictionary* extension = [bundle objectForInfoDictionaryKey:@"NSExtension"];
    NSDictionary* service = [bundle objectForInfoDictionaryKey:@"XPCService"];
    if (found || ![entry.lastPathComponent isEqual:@"NeoSwapDonor.appex"] ||
        ![[bundle objectForInfoDictionaryKey:@"NeoStationNeoSwapDonor"] isEqual:@"1"] ||
        ![[bundle objectForInfoDictionaryKey:@"NeoStationNeoSwapDonorIndex"] isEqual:@"0"] ||
        ![extension[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.ar.viewer"] ||
        ![extension[@"NSExtensionPrincipalClass"] isEqual:@"NeoSwapDonorRequestHandler"] ||
        ![extension[@"NSExtensionContextClass"] isEqual:@"NSExtensionContext"] ||
        ![extension[@"NSExtensionContextHostClass"] isEqual:@"NSExtensionContext"] ||
        ![service isEqual:expectedService] || ![bundle.bundleIdentifier isEqual:identifier]) return nil;
    found = identifier;
  }
  return found;
}
NSString* resultText(Result result) {
  return [NSString stringWithFormat:@"%s/%d", stage_name(result.stage), result.kernel_result];
}
}

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
- (void)observe:(NeoSwapDonorSession*)source index:(NSUInteger)index
       snapshot:(NeoSwapDonorSnapshot)snapshot error:(NSError*)error;
- (void)progress;
- (void)proveAllocator;
- (void)afterFirstClose;
- (void)afterBothClose;
- (BOOL)retainedContents;
@end
@implementation ProbeApp {
  NSMutableArray<NeoSwapDonorSession*>* _sessions;
  NSArray<NSString*>* _helpers;
  NSMutableArray<NSDictionary*>* _diagnostics;
  NeoSwapDonorSnapshot _samples[2];
  uint64_t _adoptedChunks[2];
  BOOL _begun[2];
  BOOL _closed[2];
  BOOL _secondStarted;
  NSInteger _growthDonor;
  uint64_t _growthBase;
  BOOL _allocatorStarted;
  BOOL _closingFirst;
  BOOL _closingSecond;
  std::vector<HeldLoan> _loans;
  NSString* _cache;
  NSDictionary* _verifiedEvidence;
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  (void)application; (void)options;
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController* controller = [UIViewController new];
  controller.view.backgroundColor = UIColor.blackColor;
  self.window.rootViewController = controller;
  [self.window makeKeyAndVisible];
  NSString* helper = ownedHelper();
  if (!helper) {
    fail(@"owned_helper_discovery", @"The exact canonical donor bundle and multiple-instance metadata were not found", nil);
    return YES;
  }
  _helpers = @[helper, helper];
  _sessions = [NSMutableArray new];
  _diagnostics = [@[@{}, @{}] mutableCopy];
  _growthDonor = -1;
  _cache = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
             stringByAppendingPathComponent:@"NeoSwapDonorProof"];
  [NSFileManager.defaultManager createDirectoryAtPath:_cache withIntermediateDirectories:YES attributes:nil error:nil];
  NeoSwapConfig config{sizeof(NeoSwapConfig), NEOSWAP_ABI, campaignTarget, 0, MiB, 1u << NEOSWAP_RPCS3, 0};
  const int configured = NeoSwap_Configure(_cache.fileSystemRepresentation, &config);
  auto campaign = pool_campaign_begin(epoch, campaignTarget);
  const NeoSwapAPI* api = NeoSwap_GetAPI(1);
  if (configured != NEOSWAP_OK || !campaign || !api || api->abi_version != 1) {
    fail(@"configure_campaign_abi1", [NSString stringWithFormat:@"configure=%d campaign=%@",
         configured, resultText(campaign)], nil);
    return YES;
  }
  __weak ProbeApp* weakSelf = self;
  for (NSUInteger index = 0; index < 2; ++index) {
    NeoSwapDonorSession* session = [[NeoSwapDonorSession alloc]
        initWithHelperIdentifier:_helpers[index] requestedBytes:donorTarget
        generation:100 + index timeout:15
        observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot snapshot, NSError* error) {
      // The two session observers run on distinct queues. All campaign state
      // and scheduling below is serialized on the host main queue.
      dispatch_async(dispatch_get_main_queue(), ^{
        ProbeApp* self = weakSelf;
        if (self && !completed.load()) [self observe:source index:index snapshot:snapshot error:error];
      });
    }];
    if (![session setInitialChunkMaximumBytes:chunkMaximum]) {
      fail(@"bounded_initial_chunk", @"The idle session refused a bounded initial real chunk", nil);
      return YES;
    }
    [_sessions addObject:session];
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self->_sessions[0] start];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!completed.load()) fail(@"app_harness_deadline",
        @"The real two-extension/chunk/allocator lifecycle did not finish",
        @{@"donors":self->_diagnostics});
  });
  return YES;
}
- (void)observe:(NeoSwapDonorSession*)source index:(NSUInteger)index
       snapshot:(NeoSwapDonorSnapshot)snapshot error:(NSError*)error {
  if (source != _sessions[index] || snapshot.generation != 100 + index) {
    fail(@"session_identity", @"An observer changed session or generation", source.diagnostics);
    return;
  }
  if (snapshot.state == NeoSwapDonorStateFailed) {
    pool_donor_lost(epoch, static_cast<uint32_t>(index), snapshot.generation, snapshot.kernelResult);
    fail(@"real_extension_donation", error.localizedDescription ?: @"Native donor failed", source.diagnostics);
    return;
  }
  if (snapshot.state == NeoSwapDonorStateClosed) {
    if (error || [source.diagnostics[@"cleanupPending"] isEqual:@YES] ||
        [source.diagnostics[@"quarantinedCleanupBlocks"] unsignedLongLongValue] ||
        (index == 0 ? !_closingFirst : !_closingSecond)) {
      fail(@"donor_close_cleanup", error.localizedDescription ?: @"Unexpected close or pending kernel cleanup", source.diagnostics);
      return;
    }
    _closed[index] = YES;
    pool_donor_lost(epoch, static_cast<uint32_t>(index), snapshot.generation, 0);
    if (index == 0) [self afterFirstClose];
    else [self afterBothClose];
    return;
  }
  if (snapshot.state != NeoSwapDonorStateActive || _closed[index]) return;
  if (snapshot.donorPID <= 0 || snapshot.donorPID == getpid() ||
      snapshot.targetBytes != donorTarget || !snapshot.capacityBytes ||
      snapshot.capacityBytes > donorTarget || !snapshot.verifiedChunkCount ||
      snapshot.donatedCompressedBytes > snapshot.capacityBytes ||
      snapshot.donatedResidentBytes > snapshot.capacityBytes - snapshot.donatedCompressedBytes ||
      snapshot.donatedResidentBytes + snapshot.donatedCompressedBytes <
          snapshot.capacityBytes - MIN(MiB, snapshot.capacityBytes / 16) ||
      (_begun[1 - index] && snapshot.donorPID == _samples[1 - index].donorPID) ||
      (_begun[index] && snapshot.donorPID != _samples[index].donorPID)) {
    fail(@"distinct_pid_kernel_accounting", @"Distinct donor PIDs and bounded measured ledger pages were not established", source.diagnostics);
    return;
  }
  if (snapshot.growthState == NeoSwapDonorGrowthRefused) {
    fail(@"actual_chunk_growth_refused", @"The kernel/headroom refused the requested second real chunk", source.diagnostics);
    return;
  }
  if (!_begun[index]) {
    auto begun = pool_donor_begin(epoch, static_cast<uint32_t>(index), snapshot.generation, snapshot.donorPID);
    if (!begun) { fail(@"pool_donor_begin", resultText(begun), source.diagnostics); return; }
    _begun[index] = YES;
  }
  const uint64_t previousChunks = _adoptedChunks[index];
  if (snapshot.verifiedChunkCount < previousChunks) {
    fail(@"chunk_count_regressed", @"A live session lost an already verified chunk", source.diagnostics);
    return;
  }
  for (uint64_t chunk = previousChunks; chunk < snapshot.verifiedChunkCount; ++chunk) {
    const uint64_t bytes = [source chunkCapacityBytes:chunk];
    mach_port_t right = [source copyMemoryEntryForChunk:chunk];
    if (!right || bytes < MiB || bytes > chunkMaximum) {
      if (right) mach_port_deallocate(mach_task_self(), right);
      fail(@"verified_chunk_handle", @"A verified indexed chunk lacked its real bounded send right", source.diagnostics);
      return;
    }
    auto adopted = pool_adopt_donor(epoch, static_cast<uint32_t>(index), snapshot.generation, chunk, right, bytes);
    const auto released = mach_port_deallocate(mach_task_self(), right);
    if (!adopted || released != KERN_SUCCESS) {
      fail(@"pool_adopt_chunk_release_right", resultText(adopted), source.diagnostics);
      return;
    }
  }
  Footprint footprint{};
  footprint.physical = snapshot.donorFootprintBytes;
  footprint.nonvolatile = snapshot.donorNonvolatileBytes;
  footprint.nonvolatile_compressed = snapshot.donorCompressedBytes;
  auto verified = pool_verify_donor(epoch, static_cast<uint32_t>(index), snapshot.generation,
      snapshot.capacityBytes, footprint, snapshot.donatedResidentBytes, snapshot.donatedCompressedBytes);
  if (!verified) { fail(@"pool_verify_measured_donor", resultText(verified), source.diagnostics); return; }
  for (uint64_t chunk = previousChunks; chunk < snapshot.verifiedChunkCount; ++chunk) {
    if (![source acknowledgeVerifiedChunk:chunk]) {
      fail(@"acknowledge_adopted_chunk", @"The retained pool chunk could not be acknowledged", source.diagnostics);
      return;
    }
  }
  _adoptedChunks[index] = snapshot.verifiedChunkCount;
  _samples[index] = snapshot;
  _diagnostics[index] = source.diagnostics;
  // One host scheduler admits only one preparing initial block. The second
  // process starts after the first block was independently mapped and acked.
  if (index == 0 && !_secondStarted) {
    _secondStarted = YES;
    [_sessions[1] start];
  }
  if (_growthDonor == static_cast<NSInteger>(index) && snapshot.capacityBytes > _growthBase)
    _growthDonor = -1;
  [self progress];
}
- (void)progress {
  if (_allocatorStarted || _growthDonor >= 0) return;
  if (!_begun[0] || !_begun[1]) return;
  for (NSUInteger index = 0; index < 2; ++index) {
    if (_samples[index].capacityBytes < donorTarget) {
      if (![_sessions[index] requestNextChunkWithMaximumBytes:chunkMaximum]) {
        fail(@"host_serial_growth_request", @"A retained verified donor refused a valid bounded host growth request", _diagnostics[index]);
        return;
      }
      _growthDonor = static_cast<NSInteger>(index);
      _growthBase = _samples[index].capacityBytes;
      return;
    }
  }
  [self proveAllocator];
}
- (void)proveAllocator {
  PoolSnapshot pool{};
  pool_snapshot(pool);
  PoolDonorSnapshot donors[2]{};
  pool_donor_snapshot(0, donors[0]);
  pool_donor_snapshot(1, donors[1]);
  const uint64_t resident = _samples[0].donatedResidentBytes + _samples[1].donatedResidentBytes;
  const uint64_t compressed = _samples[0].donatedCompressedBytes + _samples[1].donatedCompressedBytes;
  if (_adoptedChunks[0] < 2 || _adoptedChunks[1] < 2 || pool.donor_count != 2 ||
      pool.donor_pid != 0 || pool.prepared_bytes != campaignTarget ||
      pool.verified_chunks != _adoptedChunks[0] + _adoptedChunks[1] ||
      pool.resident_bytes != resident || pool.compressed_bytes != compressed ||
      resident > campaignTarget - compressed) {
    fail(@"real_aggregate_accounting", @"The aggregate pool did not equal the two independently measured donors", @{@"donors":_diagnostics});
    return;
  }
  NSMutableArray* evidence = [NSMutableArray new];
  std::vector<uint64_t> sizes;
  for (NSUInteger index = 0; index < 2; ++index) {
    if (donors[index].pid != _samples[index].donorPID ||
        donors[index].prepared_bytes != _samples[index].capacityBytes ||
        donors[index].verified_chunks != _adoptedChunks[index] ||
        donors[index].resident_bytes != _samples[index].donatedResidentBytes ||
        donors[index].compressed_bytes != _samples[index].donatedCompressedBytes) {
      fail(@"per_donor_pool_accounting", @"A donor pool ledger or chunk count did not match its real session", _diagnostics[index]);
      return;
    }
    NSMutableArray* chunks = [NSMutableArray new];
    uint64_t chunkSum = 0;
    for (uint64_t chunk = 0; chunk < _adoptedChunks[index]; ++chunk) {
      const uint64_t bytes = [_sessions[index] chunkCapacityBytes:chunk];
      if (bytes < MiB || bytes > chunkMaximum) {
        fail(@"real_chunk_capacity_report", @"A verified chunk had an invalid real capacity", _diagnostics[index]);
        return;
      }
      [chunks addObject:@{@"index":@(chunk), @"capacityBytes":@(bytes)}];
      sizes.push_back(bytes);
      chunkSum += bytes;
    }
    if (chunkSum != _samples[index].capacityBytes) {
      fail(@"real_chunk_capacity_sum", @"The measured chunk capacities did not equal the donor total", _diagnostics[index]);
      return;
    }
    [evidence addObject:@{@"helperIdentifier":_helpers[index], @"helperIndex":@"0",
        @"poolIndex":@(index), @"pid":@(_samples[index].donorPID),
        @"generation":@(_samples[index].generation), @"capacityBytes":@(_samples[index].capacityBytes),
        @"verifiedChunkCount":@(_adoptedChunks[index]), @"residentBytes":@(donors[index].resident_bytes),
        @"compressedBytes":@(donors[index].compressed_bytes), @"chunks":chunks,
        @"diagnostics":_diagnostics[index]}];
  }
  _verifiedEvidence = @{@"donors":evidence, @"capacityBytes":@(pool.prepared_bytes),
      @"donorResidentBytes":@(resident), @"donorCompressedBytes":@(compressed),
      @"verifiedChunkCount":@(pool.verified_chunks), @"donorCount":@2, @"donorBundleCount":@1,
      @"requestCount":@2};
  _allocatorStarted = YES;
  std::sort(sizes.begin(), sizes.end(), std::greater<uint64_t>());
  const NeoSwapAPI* api = NeoSwap_GetAPI(1);
  uint64_t live = 0;
  for (uint64_t size : sizes) {
    PoolDonorSnapshot before[2]{}, after[2]{};
    pool_donor_snapshot(0, before[0]); pool_donor_snapshot(1, before[1]);
    void* pointer = nullptr;
    const int allocated = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, size, 65536, &pointer);
    pool_donor_snapshot(0, after[0]); pool_donor_snapshot(1, after[1]);
    NSUInteger owner = after[0].live_bytes == before[0].live_bytes + size ? 0 : 1;
    if (allocated != NEOSWAP_OK || !pointer ||
        after[owner].live_bytes != before[owner].live_bytes + size ||
        after[1 - owner].live_bytes != before[1 - owner].live_bytes) {
      fail(@"abi1_all_verified_chunks", @"ABI1 failed to route a real whole-chunk loan to exactly one donor", nil);
      return;
    }
    unsigned char pattern = static_cast<unsigned char>(0x5a + _loans.size() % 20);
    std::memset(pointer, pattern, size);
    if (api->sync(pointer) != NEOSWAP_OK) {
      fail(@"donation_sync", @"The real ABI1 donor loan could not be synchronized", nil);
      return;
    }
    _loans.push_back({pointer, size, owner, pattern});
    live += size;
  }
  NeoSwapHostStats host{};
  NeoSwapStats stats{}; stats.struct_size = sizeof(stats);
  pool_donor_snapshot(0, donors[0]); pool_donor_snapshot(1, donors[1]);
  if (NeoSwap_HostSnapshot(&host) != NEOSWAP_OK || NeoSwap_Snapshot(&stats) != NEOSWAP_OK ||
      live != campaignTarget || !donors[0].live_bytes || !donors[1].live_bytes ||
      host.donated_live_bytes != live || host.owner_donated_live_bytes[NEOSWAP_RPCS3] != live ||
      host.donor_count != 2 || host.donor_prepared_bytes != campaignTarget ||
      host.donor_resident_bytes != resident || host.donor_accounted_compressed_bytes != compressed ||
      stats.abi_version != 1 || stats.live_bytes != live ||
      stats.owners[NEOSWAP_RPCS3].live_bytes != live || NeoSwap_LiveBytes(NEOSWAP_RPCS3) != live ||
      stats.allocated_disk_bytes) {
    fail(@"abi1_two_donor_loan_counts", @"Actual live donor loans were not separate from the file arena", nil);
    return;
  }
  NSMutableDictionary* ownerProof = [_verifiedEvidence mutableCopy];
  ownerProof[@"rpcs3DonatedLiveBytes"] = @(host.owner_donated_live_bytes[NEOSWAP_RPCS3]);
  ownerProof[@"rpcs3LiveBytes"] = @(stats.owners[NEOSWAP_RPCS3].live_bytes);
  _verifiedEvidence = ownerProof;
  // Leave one free verified block on donor 1 so the test can prove that losing
  // donor 0 preserves new loans from the independent surviving process.
  bool freedSurvivorChunk = false;
  for (auto& loan : _loans) if (loan.donor == 1 && !freedSurvivorChunk) {
    if (api->release(loan.address) != NEOSWAP_OK) {
      fail(@"prepare_surviving_donor_capacity", @"Could not release one real survivor loan", nil);
      return;
    }
    loan.address = nullptr;
    freedSurvivorChunk = true;
  }
  if (!freedSurvivorChunk) { fail(@"two_real_donor_loans", @"No independent survivor loan was recorded", nil); return; }
  _closingFirst = YES;
  [_sessions[0] close];
}
- (BOOL)retainedContents {
  for (const auto& loan : _loans) if (loan.address) {
    auto* bytes = static_cast<const unsigned char*>(loan.address);
    for (uint64_t offset = 0; offset < loan.bytes; ++offset)
      if (bytes[offset] != loan.pattern) return NO;
  }
  return YES;
}
- (void)afterFirstClose {
  PoolSnapshot pool{}; pool_snapshot(pool);
  PoolDonorSnapshot before{}; pool_donor_snapshot(1, before);
  if (![self retainedContents] || pool.donor_count != 1 || pool.lost_donor_count != 1 ||
      pool.prepared_bytes != _samples[1].capacityBytes ||
      pool.resident_bytes != before.resident_bytes || pool.compressed_bytes != before.compressed_bytes ||
      !pool.retained_live_bytes) {
    fail(@"isolate_lost_donor_preserve_live_pages", @"Losing one PID damaged retained pages or the surviving real accounting", nil);
    return;
  }
  const NeoSwapAPI* api = NeoSwap_GetAPI(1);
  void* survivingLoan = nullptr;
  const int allocated = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, MiB, 65536, &survivingLoan);
  PoolDonorSnapshot after{}; pool_donor_snapshot(1, after);
  NeoSwapStats stats{}; stats.struct_size = sizeof(stats); NeoSwap_Snapshot(&stats);
  if (allocated != NEOSWAP_OK || !survivingLoan ||
      after.live_bytes != before.live_bytes + MiB || stats.allocated_disk_bytes) {
    fail(@"surviving_pid_accepts_new_abi1_loan", @"The independent live donor did not provide a new real ABI1 loan", nil);
    return;
  }
  std::memset(survivingLoan, 0xa7, MiB);
  _loans.push_back({survivingLoan, MiB, 1, 0xa7});
  _closingSecond = YES;
  [_sessions[1] close];
}
- (void)afterBothClose {
  PoolSnapshot pool{}; pool_snapshot(pool);
  uint64_t retained = 0;
  for (const auto& loan : _loans) if (loan.address) retained += loan.bytes;
  if (![self retainedContents] || pool.donor_count || pool.lost_donor_count != 2 ||
      pool.resident_bytes || pool.compressed_bytes || pool.prepared_bytes ||
      pool.live_bytes != retained || pool.retained_live_bytes != retained) {
    fail(@"retained_data_after_both_donors_close", @"Closed PIDs remained accounted as live donors or damaged borrowed pages", nil);
    return;
  }
  void* forbidden = nullptr; uint64_t token = 0;
  if (pool_acquire(MiB, 65536, &forbidden, &token) || forbidden || token) {
    fail(@"new_donor_loans_after_both_close", @"Both disconnected PIDs still offered a new donor loan", nil);
    return;
  }
  const NeoSwapAPI* api = NeoSwap_GetAPI(1);
  void* fallback = nullptr;
  const int allocated = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, MiB, 65536, &fallback);
  NeoSwapHostStats host{}; NeoSwap_HostSnapshot(&host);
  NeoSwapStats stats{}; stats.struct_size = sizeof(stats); NeoSwap_Snapshot(&stats);
  if (allocated != NEOSWAP_OK || !fallback || host.donated_live_bytes != retained ||
      host.owner_donated_live_bytes[NEOSWAP_RPCS3] != retained ||
      stats.live_bytes != retained + MiB || stats.allocated_disk_bytes < MiB ||
      stats.owners[NEOSWAP_RPCS3].live_bytes != retained + MiB ||
      api->release(fallback) != NEOSWAP_OK) {
    fail(@"explicit_file_fallback_after_both_close", @"File fallback did not preserve and separately count retained donor loans", nil);
    return;
  }
  for (auto& loan : _loans) if (loan.address) {
    void* stale = loan.address;
    if (api->sync(stale) != NEOSWAP_OK || api->release(stale) != NEOSWAP_OK ||
        api->release(stale) != NEOSWAP_NOT_OWNED) {
      fail(@"retained_abi1_sync_release_stale", @"ABI1 did not safely sync/release the retained donor loan", nil);
      return;
    }
    loan.address = nullptr;
  }
  NeoSwap_HostSnapshot(&host);
  auto retired = pool_campaign_begin(epoch + 1, campaignTarget);
  pool_snapshot(pool);
  CleanupSnapshot cleanup{}; cleanup_snapshot(cleanup);
  NeoSwapConfig disabled{sizeof(NeoSwapConfig), NEOSWAP_ABI, 0, 0, MiB, 1u << NEOSWAP_RPCS3, 0};
  if (host.donated_live_bytes || host.owner_donated_live_bytes[NEOSWAP_RPCS3] ||
      NeoSwap_LiveBytes(NEOSWAP_RPCS3) || !retired || pool.retained_bytes || pool.live_bytes ||
      cleanup.pending_blocks || NeoSwap_Configure(_cache.fileSystemRepresentation, &disabled) != NEOSWAP_OK) {
    fail(@"retire_real_kernel_mappings", @"Released campaign mappings or file arena remained owned", nil);
    return;
  }
  NSMutableDictionary* report = [_verifiedEvidence mutableCopy];
  [report addEntriesFromDictionary:@{@"schema":@2, @"passed":@YES, @"platform":@"iOS18Simulator",
      @"transport":@"real-NSExtension-auxiliary-NSXPC", @"realIPhoneValidated":@NO,
      @"physicalIphoneValidated":@NO, @"hostPID":@(getpid()), @"abiVersion":@1,
      @"realDonationLoanBytes":@(campaignTarget), @"donationDiskBytes":@0,
      @"retainedDataAfterClose":@YES, @"newLoansBlockedAfterClose":@YES,
      @"survivingDonorNewLoanPassed":@YES, @"explicitFileFallbackPassed":@YES,
      @"releasePassed":@YES, @"kernelMappingCleanupPassed":@YES}];
  finish(report);
}
@end
int main(int argc, char* argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class)); }
}
'''


def run(arguments: list[str], *, timeout: int = 60, capture: bool = False) -> str:
    try:
        result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        LOGS.append('COMMAND ' + ' '.join(arguments) + '\nTIMEOUT\n' + output)
        raise
    LOGS.append('COMMAND ' + ' '.join(arguments) + '\n' + (result.stdout or ''))
    if not capture and result.stdout:
        print(result.stdout)
    result.check_returncode()
    return result.stdout or ''


def sdk_runtime() -> tuple[str, str, str]:
    # A fresh hosted runner can spend over a minute initializing CoreSimulator.
    # This only extends service discovery; every launch/PID/page proof stays required.
    runtimes = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '--json'],
                             capture=True, timeout=180))['runtimes']
    candidates = [runtime for runtime in runtimes if runtime.get('isAvailable') and
                  runtime.get('version', '').split('.')[0] == '18' and
                  'SimRuntime.iOS-' in runtime['identifier']]
    if not candidates:
        raise RuntimeError('Required real iOS 18 Simulator runtime is unavailable; runtime proof is not skipped')
    sdk_version = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], capture=True).strip()
    sdk_pair = tuple(sdk_version.split('.')[:2])
    paired = [runtime for runtime in candidates if tuple(runtime['version'].split('.')[:2]) == sdk_pair]
    runtime = sorted(paired or candidates, key=lambda item: tuple(map(int, item['version'].split('.'))))[-1]
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], capture=True).strip()
    return sdk, runtime['identifier'], sdk_version


def plist(path: Path, value: dict) -> None:
    path.write_bytes(plistlib.dumps(value))


def simulator_executable(path: Path, architecture: str) -> dict:
    """Inspect the actual compiled header and platform, independently of flags."""
    data = path.read_bytes()
    expected_cpu = {'arm64':0x0100000C, 'x86_64':0x01000007}[architecture]
    if len(data) < 32 or data[:4] != b'\xcf\xfa\xed\xfe':
        raise RuntimeError(f'{path.name} is not a thin 64-bit Mach-O executable')
    _, cpu, _, filetype, count, command_bytes, _, _ = struct.unpack_from('<8I', data)
    if cpu != expected_cpu or filetype != 2 or 32 + command_bytes > len(data):
        raise RuntimeError(f'{path.name} has an unexpected CPU, filetype or load-command range')
    end = 32 + command_bytes
    position = 32
    platforms = []
    for _ in range(count):
        if position + 8 > end:
            raise RuntimeError(f'{path.name} has truncated Mach-O commands')
        command, size = struct.unpack_from('<II', data, position)
        if size < 8 or position + size > end:
            raise RuntimeError(f'{path.name} has an invalid Mach-O command size')
        if command == 0x32:  # LC_BUILD_VERSION
            if size < 24:
                raise RuntimeError(f'{path.name} has a truncated build-version command')
            platforms.append(struct.unpack_from('<I', data, position + 8)[0])
        position += size
    if platforms != [7]:  # PLATFORM_IOSSIMULATOR
        raise RuntimeError(f'{path.name} was not actually compiled for iOS Simulator: {platforms}')
    return {'cpuType':cpu, 'fileType':filetype, 'buildPlatforms':platforms}


def build(work: Path, sdk: str, report: dict) -> tuple[Path, dict[str, str]]:
    app = work / 'NeoSwapSimulator.app'
    (app / 'PlugIns').mkdir(parents=True)
    simulator_host = work / 'SimulatorHost.mm'
    simulator_host.write_text(HARNESS)
    # The exact canonical C ABI broker is copied unchanged to give its Donation/
    # include a canonical namespace without depending on generated pod files.
    abi = work / 'CanonicalABI'
    abi.mkdir()
    for name in ('NeoSwap.cpp', 'NeoSwap.h', 'NeoSwapHost.h'):
        shutil.copyfile(HOST / name, abi / name)
    (abi / 'Donation').symlink_to(DONATION, target_is_directory=True)
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise RuntimeError(f'Unsupported Simulator runner architecture: {architecture}')
    common = ['xcrun', '--sdk', 'iphonesimulator', 'clang++', '-x', 'objective-c++', '-std=c++20',
              '-O1', '-g', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
              '-isysroot', sdk, '-target', f'{architecture}-apple-ios18.0-simulator',
              '-I', str(DONATION), '-I', str(abi), '-framework', 'Foundation',
              '-framework', 'UIKit', '-framework', 'Security']
    host_sources = [DONATION / name for name in
                    ('Broker.cpp', 'Pool.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorIPC.mm')]
    host_sources += [abi / 'NeoSwap.cpp', simulator_host]
    helper_sources = [DONATION / name for name in
                      ('Broker.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorRequestHandler.mm')]
    run(common + ['-DNEOSWAP_DONATION=1'] + list(map(str, host_sources)) + ['-o', str(app / 'NeoSwapSimulator')], timeout=120)
    info = {'CFBundleIdentifier':BUNDLE, 'CFBundleExecutable':'NeoSwapSimulator',
            'CFBundleName':'NeoSwapSimulator', 'CFBundlePackageType':'APPL',
            'CFBundleInfoDictionaryVersion':'6.0', 'CFBundleSupportedPlatforms':['iPhoneSimulator'],
            'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'18.0',
            'UIDeviceFamily':[1, 2], 'LSRequiresIPhoneOS':True, 'UILaunchScreen':{},
            'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait']}
    plist(app / 'Info.plist', info)
    entitlements = DONATION / 'NeoSwapDonor.entitlements'
    simulator_entitlements = work / 'Simulator.entitlements'
    plist(simulator_entitlements, {})
    report['buildPreflight'] = {'hostInfo':info, 'architecture':architecture, 'helpers':{},
                                'initialChunkMaximumBytes':16 * 1024**2,
                                'targetBytesPerPID':PROBE_DONOR_BYTES,
                                'campaignTargetBytes':2 * PROBE_DONOR_BYTES}
    if set(DONOR_CONTRACTS) != set(PROBE_HELPERS):
        raise RuntimeError('The Simulator proof requires exactly one canonical donor bundle')
    for expected_index, name in enumerate(PROBE_HELPERS):
        contract = DONOR_CONTRACTS[name]
        if contract['index'] != str(expected_index):
            raise RuntimeError(f'Canonical probe donor index changed: {name}')
        helper = app / 'PlugIns' / name
        helper.mkdir()
        executable = name.removesuffix('.appex')
        run(common + ['-fapplication-extension', '-Wl,-e,_NSExtensionMain'] + list(map(str, helper_sources)) +
            ['-o', str(helper / executable)], timeout=120)
        helper_info = plistlib.loads((DONATION / 'Info.plist').read_bytes())
        metadata = helper_info.get('NSExtension', {})
        service = helper_info.get('XPCService')
        expected_service = {'ServiceType':'Application', '_MultipleInstances':True, '_ProcessType':'App'}
        if (not isinstance(metadata, dict) or metadata.get('NSExtensionPointIdentifier') != 'com.apple.ar.viewer' or
                metadata.get('NSExtensionContextClass') != 'NSExtensionContext' or
                metadata.get('NSExtensionContextHostClass') != 'NSExtensionContext' or
                not isinstance(service, dict) or service != expected_service or
                service.get('_MultipleInstances') is not True):
            raise RuntimeError('Canonical donor multiple-instance/context metadata is inconsistent')
        helper_info.update({'CFBundleIdentifier':BUNDLE + contract['bundleSuffix'],
                            'CFBundleExecutable':executable, 'CFBundleName':executable,
                            'CFBundleDevelopmentRegion':'en', 'NeoStationNeoSwapDonorIndex':contract['index'],
                            'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0',
                            'CFBundleSupportedPlatforms':['iPhoneSimulator']})
        plist(helper / 'Info.plist', helper_info)
        if b'$(' in plistlib.dumps(helper_info):
            raise RuntimeError(f'{name} still contains unresolved build settings')
        run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(helper)])
        actual_entitlements = embedded_entitlements((helper / executable).read_bytes())
        require_entitlements(actual_entitlements, REQUIRED_DONOR_ENTITLEMENTS, executable)
        if set(actual_entitlements) != set(REQUIRED_DONOR_ENTITLEMENTS):
            raise RuntimeError(f'{name} has unexpected actual embedded signature entitlements')
        production_signature_preflight = actual_entitlements
        # macOS AMFI rejects these restricted device-only capabilities on a
        # Simulator process. Keep their native signature preflight above, then
        # run the actual extension with an explicitly empty Simulator signature.
        run(['codesign', '--force', '--sign', '-', '--entitlements',
             str(simulator_entitlements), str(helper)])
        actual_entitlements = embedded_entitlements((helper / executable).read_bytes())
        if actual_entitlements:
            raise RuntimeError(f'{name} retained device-only capabilities in its Simulator signature')
        report['buildPreflight']['helpers'][name] = {
            'info':helper_info, 'machO':simulator_executable(helper / executable, architecture),
            'embeddedEntitlementValues':actual_entitlements,
            'productionCapabilitySignaturePreflight':production_signature_preflight,
            'otoolHeaders':run(['xcrun', 'otool', '-hv', str(helper / executable)], capture=True),
            'otoolLoadCommands':run(['xcrun', 'otool', '-l', str(helper / executable)], capture=True),
            'signature':run(['codesign', '--display', '--verbose=4', str(helper)], capture=True),
            'embeddedEntitlements':run(['codesign', '--display', '--entitlements', ':-', str(helper)], capture=True),
        }
    host_entitlements = work / 'host.entitlements'
    plist(host_entitlements, {})
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(host_entitlements), str(app)])
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)])
    report['buildPreflight'].update({
        'hostMachO':simulator_executable(app / 'NeoSwapSimulator', architecture),
        'hostOtoolHeaders':run(['xcrun', 'otool', '-hv', str(app / 'NeoSwapSimulator')], capture=True),
        'hostOtoolLoadCommands':run(['xcrun', 'otool', '-l', str(app / 'NeoSwapSimulator')], capture=True),
        'hostSignature':run(['codesign', '--display', '--verbose=4', str(app)], capture=True),
        'hostEmbeddedEntitlements':run(['codesign', '--display', '--entitlements', ':-', str(app)], capture=True),
        'nestedSignatureVerified':True,
    })
    source_files = [DONATION / name for name in ('Broker.cpp', 'Broker.h', 'Pool.cpp', 'Pool.h',
                    'NeoSwapMachHandle.mm', 'NeoSwapMachHandle.h', 'NeoSwapDonorIPC.mm', 'NeoSwapDonorIPC.h',
                    'NeoSwapDonorRequestHandler.mm', 'NeoSwapDonorRequestHandler.h', 'Info.plist',
                    'NeoSwapDonor.entitlements')]
    source_files += [HOST / name for name in ('NeoSwap.cpp', 'NeoSwap.h', 'NeoSwapHost.h')]
    source_files += [Path(__file__).resolve(), ROOT / 'build-utils/configure_neoswap_donor.py']
    hashes = {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    return app, hashes


def validate_evidence(report: dict) -> None:
    """Require the native proof's two actual PIDs and measured sum, not flags alone."""
    if (not isinstance(report, dict) or type(report.get('schema')) is not int or report['schema'] != 2 or
            report.get('platform') != 'iOS18Simulator' or
            report.get('transport') != 'real-NSExtension-auxiliary-NSXPC'):
        raise RuntimeError('The actual Simulator proof has an invalid schema, platform or transport')
    if report.get('passed') is not True or type(report.get('abiVersion')) is not int or report['abiVersion'] != 1:
        raise RuntimeError('The actual Simulator allocation proof did not pass ABI 1')
    if report.get('physicalIphoneValidated') is not False or report.get('realIPhoneValidated') is not False:
        raise RuntimeError('A Simulator report must not claim physical iPhone validation')
    for flag in ('retainedDataAfterClose', 'newLoansBlockedAfterClose', 'survivingDonorNewLoanPassed',
                 'explicitFileFallbackPassed', 'releasePassed', 'kernelMappingCleanupPassed'):
        if report.get(flag) is not True:
            raise RuntimeError(f'The actual Simulator lifecycle proof is missing {flag}')
    host_pid = report.get('hostPID')
    donors = report.get('donors')
    if type(host_pid) is not int or host_pid <= 0 or not isinstance(donors, list) or len(donors) != 2:
        raise RuntimeError('The actual Simulator proof must contain one host and two donor PIDs')
    pids = {host_pid}
    capacity = resident = compressed = chunks = 0
    for index, donor in enumerate(donors):
        name = PROBE_HELPERS[0]
        contract = DONOR_CONTRACTS[name]
        if (not isinstance(donor, dict) or donor.get('helperIdentifier') != BUNDLE + contract['bundleSuffix'] or
                donor.get('helperIndex') != '0' or donor.get('helperIndex') != contract['index'] or
                type(donor.get('poolIndex')) is not int or donor['poolIndex'] != index or
                type(donor.get('generation')) is not int or donor['generation'] != 100 + index):
            raise RuntimeError(f'The actual donor identity/index is inconsistent: {name}')
        pid = donor.get('pid')
        if type(pid) is not int or pid <= 0 or pid in pids:
            raise RuntimeError(f'{name} did not run in its own distinct donor PID')
        pids.add(pid)
        values = [donor.get(key) for key in ('capacityBytes', 'residentBytes', 'compressedBytes', 'verifiedChunkCount')]
        if any(type(value) is not int or value < 0 for value in values):
            raise RuntimeError(f'{name} did not provide real numeric chunk/ledger counters')
        donor_capacity, donor_resident, donor_compressed, donor_chunks = values
        if (not 2 <= donor_chunks <= 64 or donor_capacity != PROBE_DONOR_BYTES or
                donor_resident + donor_compressed > donor_capacity or
                donor_resident + donor_compressed < donor_capacity - min(1024**2, donor_capacity // 16)):
            raise RuntimeError(f'{name} did not establish at least two independently charged real chunks')
        actual_chunks = donor.get('chunks')
        if not isinstance(actual_chunks, list) or len(actual_chunks) != donor_chunks:
            raise RuntimeError(f'{name} did not report each independently verified chunk')
        chunk_sum = 0
        for chunk_index, chunk in enumerate(actual_chunks):
            if (not isinstance(chunk, dict) or type(chunk.get('index')) is not int or chunk['index'] != chunk_index or
                    type(chunk.get('capacityBytes')) is not int or
                    not 1024**2 <= chunk['capacityBytes'] <= 16 * 1024**2):
                raise RuntimeError(f'{name} reported an invalid chunk index or unbounded chunk capacity')
            chunk_sum += chunk['capacityBytes']
        if chunk_sum != donor_capacity:
            raise RuntimeError(f'{name} chunk capacities do not equal its actual donor total')
        capacity += donor_capacity
        resident += donor_resident
        compressed += donor_compressed
        chunks += donor_chunks
    expected = {'donorCount':2, 'donorBundleCount':1, 'requestCount':2,
                'capacityBytes':capacity, 'donorResidentBytes':resident,
                'donorCompressedBytes':compressed, 'verifiedChunkCount':chunks,
                'realDonationLoanBytes':capacity, 'rpcs3DonatedLiveBytes':capacity,
                'rpcs3LiveBytes':capacity, 'donationDiskBytes':0}
    if any(type(report.get(key)) is not int or report[key] != value for key, value in expected.items()):
        raise RuntimeError('The aggregate proof does not equal the two actual donors and their ABI 1 loans')


def main() -> int:
    parser = argparse.ArgumentParser()
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument('--report', type=Path)
    destination.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or args.report.parent
    report_path = args.report or (output / 'report.json')
    report = {'schema':2, 'passed':False, 'platform':'iOS18Simulator',
              'realIPhoneValidated':False, 'physicalIphoneValidated':False}
    identifier: str | None = None
    campaign_started = time.time()
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('A real Apple Simulator runner is required; this proof is not mocked or skipped')
        sdk, runtime, sdk_version = sdk_runtime()
        report.update({'runtime':runtime, 'sdkVersion':sdk_version, 'runnerStage':'build'})
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-simulator-') as directory:
            app, hashes = build(Path(directory), sdk, report)
            report.update({'sourceSHA256':hashes, 'runnerStage':'boot_install'})
            output.mkdir(parents=True, exist_ok=True)
            (output / 'build-preflight.json').write_text(json.dumps(report, indent=2) + '\n')
            (output / 'SimulatorHost.mm').write_text(HARNESS)
            device_types = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '--json'], capture=True))['devicetypes']
            matches = [item for item in device_types if item['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro']
            if not matches:
                raise RuntimeError('iPhone 16 Pro Simulator device type is unavailable')
            identifier = run(['xcrun', 'simctl', 'create', 'NeoSwapDonorProof', matches[0]['identifier'], runtime], capture=True).strip()
            run(['xcrun', 'simctl', 'boot', identifier])
            run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
            run(['xcrun', 'simctl', 'install', identifier, str(app)], timeout=90)
            report['runnerStage'] = 'installed_prelaunch'
            container = Path(run(['xcrun', 'simctl', 'get_app_container', identifier, BUNDLE, 'data'], capture=True).strip())
            report['installedRegistration'] = run(['xcrun', 'simctl', 'listapps', identifier], capture=True)[-20000:]
            (output / 'installed-prelaunch.json').write_text(json.dumps(report, indent=2) + '\n')
            report['runnerStage'] = 'launch'
            launched = run(['xcrun', 'simctl', 'launch', identifier, BUNDLE], capture=True, timeout=90)
            report['launchOutput'] = launched
            report['runnerStage'] = 'runtime_evidence'
            evidence = container / 'Documents/donation-simulator.json'
            deadline = time.monotonic() + 60
            while not evidence.is_file() and time.monotonic() < deadline:
                time.sleep(1)
            if not evidence.is_file():
                raise RuntimeError('Actual Simulator app did not produce extension/allocator proof; launch output: ' + launched[-12000:])
            report.update(json.loads(evidence.read_text()))
            if report.get('passed') is not True:
                raise RuntimeError(report.get('technicalError') or 'The actual extension lifecycle failed')
            validate_evidence(report)
            report['runnerStage'] = 'complete'
            print(json.dumps(report, indent=2, ensure_ascii=False))
            return 0
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as exception:
        report['passed'] = False
        report['runnerError'] = str(exception)
        print(str(exception), file=sys.stderr)
        if identifier:
            # Preserve actual donor startup failures before deleting our device.
            # Only reports named for this harness and produced during this run
            # are copied; successful page/ledger assertions remain mandatory.
            crash_roots = [Path.home() / 'Library/Logs/DiagnosticReports',
                           Path.home() / 'Library/Developer/CoreSimulator/Devices' /
                           identifier / 'data/Library/Logs/CrashReporter']
            for root in crash_roots:
                for crash in sorted(root.glob('NeoSwapDonor*')):
                    try:
                        if (crash.is_file() and crash.suffix in ('.ips', '.crash') and
                                crash.stat().st_mtime >= campaign_started):
                            output.mkdir(parents=True, exist_ok=True)
                            shutil.copyfile(crash, output / crash.name)
                            report.setdefault('donorCrashReports', []).append(crash.name)
                    except OSError as crash_error:
                        report.setdefault('crashCollectionErrors', []).append(str(crash_error))
            try:
                logs = run(['xcrun', 'simctl', 'spawn', identifier, 'log', 'show', '--last', '2m',
                            '--style', 'compact', '--predicate',
                            '(process IN {"NeoSwapDonor", "NeoSwapSimulator", '
                            '"SpringBoard", "runningboardd", "launchd_sim", "launchd", "launchservicesd", "installd", "pkd"}) '
                            'AND (eventMessage CONTAINS[c] "NeoSwap" OR '
                            f'eventMessage CONTAINS[c] "{BUNDLE}" OR '
                            'eventMessage CONTAINS[c] "FBS" OR eventMessage CONTAINS[c] "denied")'],
                           capture=True, timeout=40)
                report['simulatorLogs'] = logs[-30000:]
            except subprocess.SubprocessError as log_error:
                report['simulatorLogError'] = str(log_error)
                report['simulatorLogPartial'] = LOGS[-1][-30000:]
        return 1
    finally:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        if identifier:
            for action in ('shutdown', 'delete'):
                try:
                    run(['xcrun', 'simctl', action, identifier], capture=True, timeout=20)
                except subprocess.SubprocessError as cleanup_error:
                    print(f'Own Simulator {action} failed: {cleanup_error}', file=sys.stderr)
        output.mkdir(parents=True, exist_ok=True)
        (output / 'runner.log').write_text('\n'.join(LOGS))


if __name__ == '__main__':
    raise SystemExit(main())
