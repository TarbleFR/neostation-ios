#import "NeoSwapDonorRequestHandler.h"
#import "NeoSwapDonorIPC.h"
#include "Broker.h"
#include "DonorLedger.h"

#import <objc/message.h>
#import <objc/runtime.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <cstring>
#include <memory>
#include <vector>
#include <unistd.h>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
using HeadroomQuery = size_t (*)(void);
HeadroomQuery headroomQuery() {
  static HeadroomQuery query = reinterpret_cast<HeadroomQuery>(
      dlsym(RTLD_DEFAULT, "os_proc_available_memory"));
  return query;
}
uint64_t headroom() {
  HeadroomQuery query = headroomQuery();
  return query ? query() : 0;
}
NSError* error(NSString* description) {
  return [NSError errorWithDomain:@"NeoSwapDonation" code:3201
                        userInfo:@{NSLocalizedDescriptionKey:description}];
}
BOOL numeric(NSDictionary* dictionary, NSString* key) {
  return [dictionary[key] isKindOfClass:NSNumber.class];
}
NSDictionary* effectiveEntitlements() {
  using Create = CFTypeRef (*)(CFAllocatorRef);
  using Copy = CFTypeRef (*)(CFTypeRef, CFStringRef, CFErrorRef*);
  static Create create = reinterpret_cast<Create>(dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf"));
  static Copy copy = reinterpret_cast<Copy>(dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement"));
  CFTypeRef task = create ? create(kCFAllocatorDefault) : NULL;
  NSMutableDictionary* values = [NSMutableDictionary new];
  for (NSString* name in @[@"get-task-allow", @"com.apple.developer.kernel.increased-memory-limit",
                           @"com.apple.developer.kernel.increased-debugging-memory-limit"]) {
    if (!task || !copy) { values[name] = NSNull.null; continue; }
    CFErrorRef error = NULL;
    CFTypeRef value = copy(task, (__bridge CFStringRef)name, &error);
    if (value && CFGetTypeID(value) == CFBooleanGetTypeID())
      values[name] = @((BOOL)CFBooleanGetValue(static_cast<CFBooleanRef>(value)));
    else values[name] = error || value ? NSNull.null : @NO;
    if (value) CFRelease(value);
    if (error) CFRelease(error);
  }
  if (task) CFRelease(task);
  return values;
}
}

@implementation NeoSwapDonorContext
+ (NSXPCInterface*)_extensionAuxiliaryHostProtocol {
  return NeoSwapDonorHostInterface();
}
+ (NSXPCInterface*)_extensionAuxiliaryVendorProtocol {
  return [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapDonorVendorProtocol)];
}
@end

@implementation NeoSwapDonorRequestHandler {
  dispatch_queue_t _queue;
  dispatch_source_t _heartbeat;
  NSExtensionContext* _context;
  NSXPCConnection* _connection;
  NSString* _nonce;
  uint64_t _generation;
  uint64_t _target;
  uint64_t _capacity;
  uint64_t _chunkBytes;
  uint64_t _headroom;
  uint64_t _chunkAccountedDelta;
  uint64_t _refusedBytes;
  NSString* _growthStage;
  BOOL _growthRefused;
  BOOL _proofComplete;
  BOOL _preparing;
  BOOL _updateInFlight;
  BOOL _processHeadroomRequired;
  BOOL _closed;
  std::vector<std::unique_ptr<neostation::donation::Block>> _blocks;
  std::unique_ptr<neostation::donation::Block> _pending;
  neostation::donation::Footprint _baseline;
  neostation::donation::Footprint _chunkBaseline;
  neostation::donation::SystemHeadroom _system;
  NSDictionary* _effectiveEntitlements;
}

- (instancetype)init {
  if ((self = [super init]))
    _queue = dispatch_queue_create("com.neogamelab.neostation.neoswap-donor-helper", DISPATCH_QUEUE_SERIAL);
  return self;
}

- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
  dispatch_async(_queue, ^{
    if (self->_context || self->_connection || self->_closed) {
      [context cancelRequestWithError:error(@"The dedicated donor already has a live request")];
      return;
    }
    self->_context = context;
    SEL getConnection = NSSelectorFromString(@"_auxiliaryConnection");
    if (![context respondsToSelector:getConnection]) {
      [context cancelRequestWithError:error(@"NSExtension auxiliary XPC connection unavailable")];
      self->_context = nil;
      self->_closed = YES;
      return;
    }
    using Get = id (*)(id, SEL);
    id connection = reinterpret_cast<Get>(objc_msgSend)(context, getConnection);
    if (![connection isKindOfClass:NSXPCConnection.class]) {
      [context cancelRequestWithError:error(@"NSExtension did not supply an auxiliary XPC connection")];
      self->_context = nil;
      self->_closed = YES;
      return;
    }
    NSXPCConnection* auxiliary = connection;
    Protocol* hostProtocol = auxiliary.remoteObjectInterface.protocol;
    Protocol* vendorProtocol = auxiliary.exportedInterface.protocol;
    if (![context isKindOfClass:NeoSwapDonorContext.class] || !hostProtocol || !vendorProtocol ||
        !protocol_conformsToProtocol(hostProtocol, @protocol(NeoSwapDonorHostProtocol)) ||
        !protocol_isEqual(vendorProtocol, @protocol(NeoSwapDonorVendorProtocol))) {
      [context cancelRequestWithError:error(@"Donor auxiliary interfaces were not configured before the request")];
      self->_context = nil;
      self->_closed = YES;
      return;
    }
    id item = context.inputItems.firstObject;
    NSDictionary* metadata = [item isKindOfClass:NSExtensionItem.class] ? [item userInfo] : nil;
    [self beginWithConnection:connection metadata:metadata probe:NO];
  });
}

- (void)beginWithConnection:(NSXPCConnection*)connection
                   metadata:(NSDictionary*)metadata probe:(BOOL)probe {
  if (_closed || _connection || ![metadata isKindOfClass:NSDictionary.class] ||
      ![metadata[@"version"] isEqual:@2] ||
      ![metadata[@"nonce"] isKindOfClass:NSString.class] ||
      [metadata[@"nonce"] length] < 16 || [metadata[@"nonce"] length] > 128 ||
      !numeric(metadata, @"generation") || ![metadata[@"generation"] unsignedLongLongValue] ||
      !numeric(metadata, @"targetBytes") || !numeric(metadata, @"initialMaximumBytes") ||
      !numeric(metadata, @"hostPID") || [metadata[@"hostPID"] intValue] <= 0 ||
      [metadata[@"hostPID"] intValue] != connection.processIdentifier ||
      connection.processIdentifier == getpid()) {
    [_context cancelRequestWithError:error(@"Invalid donor request nonce/generation/host process")];
    _context = nil;
    [connection invalidate];
    _closed = YES;
    return;
  }
  _connection = connection;
  _processHeadroomRequired = !probe && !TARGET_OS_SIMULATOR;
  _effectiveEntitlements = effectiveEntitlements();
  _nonce = [metadata[@"nonce"] copy];
  _generation = [metadata[@"generation"] unsignedLongLongValue];
  _target = [metadata[@"targetBytes"] unsignedLongLongValue];
  const uint64_t initial = [metadata[@"initialMaximumBytes"] unsignedLongLongValue];
  _connection.remoteObjectInterface = NeoSwapDonorHostInterface();
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  // This is only the own auxiliary connection, whose exported context remains
  // managed by Foundation. Growth commands arrive in authenticated host replies.
  void (^lost)(void) = ^{
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  };
  _connection.invalidationHandler = lost;
  _connection.interruptionHandler = lost;
  if (!_target || _target > 8ULL * 1024 * MiB || _target % vm_page_size ||
      initial < MiB || initial > 64 * MiB || initial > _target || initial % vm_page_size) {
    [self failStage:@"requested_size" kernel:KERN_INVALID_ARGUMENT];
    return;
  }
  auto measured = neostation::donation::footprint(_baseline);
  if (!measured) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(measured.stage)]
             kernel:measured.kernel_result];
    return;
  }
  _heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_heartbeat, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(_heartbeat, ^{
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self && !self->_closed && !self->_preparing && self->_proofComplete) [self sendUpdate];
  });
  dispatch_resume(_heartbeat);
  [self prepareChunk:initial];
}

- (void)stopGrowth:(NSString*)stage requested:(uint64_t)bytes kernel:(int32_t)kernel {
  if (_pending) {
    const auto released = _pending->reset();
    if (!released) {
      [self failStage:@"growth_mapping_cleanup" kernel:released.kernel_result];
      return;
    }
    _pending.reset();
  }
  _preparing = NO;
  if (_blocks.empty()) { [self failStage:stage kernel:kernel]; return; }
  _proofComplete = YES;
  _growthRefused = YES;
  _growthStage = stage;
  _refusedBytes = bytes;
  _chunkBytes = _blocks.back()->size();
  [self sendUpdate];
}

- (void)prepareChunk:(uint64_t)maximum {
  if (_closed || _preparing || _pending || maximum < MiB || maximum > neostation::donation::max_chunk_bytes ||
      maximum % vm_page_size || maximum > _target - _capacity || _blocks.size() >= 64) {
    [self failStage:@"chunk_request" kernel:KERN_INVALID_ARGUMENT];
    return;
  }
  _preparing = YES;
  _headroom = headroom();
  if (_processHeadroomRequired && !headroomQuery()) {
    [self stopGrowth:@"headroom_api_unavailable" requested:maximum kernel:KERN_NOT_SUPPORTED];
    return;
  }
  auto systemStatus = neostation::donation::system_headroom(_system);
  if (!systemStatus) {
    [self stopGrowth:[NSString stringWithUTF8String:neostation::donation::stage_name(systemStatus.stage)]
          requested:maximum kernel:systemStatus.kernel_result];
    return;
  }
  // Process headroom is a jetsam limit; system headroom is shared across every
  // donor and the emulator. Neither entitlements nor a target create extra RAM.
  // Keep another MiB for Block/XPC setup before the repeated 16 MiB process
  // and 512 MiB system margin checks, so a small extension is not refused merely
  // because its metadata consumed a few pages after the first sample.
  const uint64_t processBudget = neostation::donation::process_headroom_budget(
      _headroom, _processHeadroomRequired, 17 * MiB);
  const uint64_t systemBudget = _system.usable_bytes > MiB ? _system.usable_bytes - MiB : 0;
  // Growth serves one actual contiguous host buffer. Several smaller memory
  // entries cannot cover that loan, so refuse before creating an undersized
  // object while keeping all previously verified chunks alive.
  if (!_blocks.empty() && (processBudget < maximum || systemBudget < maximum)) {
    [self stopGrowth:systemBudget < maximum ? @"required_chunk_exceeds_system_headroom"
                                           : @"required_chunk_exceeds_donor_headroom"
          requested:maximum kernel:KERN_RESOURCE_SHORTAGE];
    return;
  }
  _chunkBytes = MIN(maximum, MIN(processBudget, systemBudget));
  _chunkBytes -= _chunkBytes % vm_page_size;
  if (_chunkBytes < MiB) {
    [self stopGrowth:systemBudget < MiB ? @"insufficient_system_headroom" : @"insufficient_donor_headroom"
          requested:maximum kernel:KERN_RESOURCE_SHORTAGE];
    return;
  }
  auto measured = neostation::donation::footprint(_chunkBaseline);
  if (!measured) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(measured.stage)]
             kernel:measured.kernel_result];
    return;
  }
  _pending = std::make_unique<neostation::donation::Block>();
  auto allocated = neostation::donation::Block::create_owned(_chunkBytes, *_pending);
  if (!allocated) {
    [self stopGrowth:[NSString stringWithUTF8String:neostation::donation::stage_name(allocated.stage)]
          requested:maximum kernel:allocated.kernel_result];
    return;
  }
  const uint64_t index = _blocks.size();
  const uint64_t pattern = NeoSwapDonorChunkPattern(_nonce, _generation, index, NO);
  auto bytes = static_cast<unsigned char*>(_pending->data());
  // Fill the actual pages with varying data, instead of charging zero pages or
  // presenting an untouched virtual reservation as physical donation.
  uint64_t random = pattern;
  for (uint64_t offset = 0; offset < _chunkBytes; offset += vm_page_size) {
    if (offset % (8 * MiB) == 0) {
      auto status = neostation::donation::system_headroom(_system);
      if (!status || _system.usable_bytes < _chunkBytes - offset ||
          neostation::donation::process_headroom_budget(
              headroom(), _processHeadroomRequired, 16 * MiB) < _chunkBytes - offset) {
        [self stopGrowth:!status ? [NSString stringWithUTF8String:neostation::donation::stage_name(status.stage)]
                                    : @"headroom_changed_during_page_preparation"
              requested:maximum kernel:!status ? status.kernel_result : KERN_RESOURCE_SHORTAGE];
        return;
      }
    }
    for (uint64_t word = 0; word < vm_page_size; word += sizeof(uint64_t)) {
      random += 0x9e3779b97f4a7c15ULL;
      uint64_t value = random;
      value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
      value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
      value ^= value >> 31;
      std::memcpy(bytes + offset + word, &value, sizeof(value));
    }
    std::memcpy(bytes + offset, &pattern, sizeof(pattern));
  }
  _proofComplete = NO;
  NeoSwapMachHandle* handle = [[NeoSwapMachHandle alloc] initWithMemoryEntry:_pending->entry()
                                                            capacityBytes:_chunkBytes];
  if (!handle) { [self failStage:@"mach_right_transport" kernel:KERN_NOT_SUPPORTED]; return; }
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  id<NeoSwapDonorHostProtocol> host = [_connection remoteObjectProxyWithErrorHandler:^(NSError* failure) {
    (void)failure;
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  }];
  [host donorReady:handle metadata:[self metadata] reply:^(BOOL accepted) {
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (!self) return;
    dispatch_async(self->_queue, ^{
      if (self->_closed) return;
      if (!accepted) { [self finish]; return; }
      const uint64_t expected = NeoSwapDonorChunkPattern(self->_nonce, self->_generation, index, YES);
      auto bytes = static_cast<unsigned char*>(self->_pending->data());
      for (uint64_t offset = 0; offset < self->_chunkBytes; offset += vm_page_size) {
        uint64_t actual = 0;
        std::memcpy(&actual, bytes + offset, sizeof(actual));
        if (actual != expected) {
          [self failStage:@"host_shared_page_proof" kernel:KERN_INVALID_ADDRESS];
          return;
        }
      }
      neostation::donation::Footprint after;
      auto status = neostation::donation::footprint(after);
      if (!status) {
        [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(status.stage)]
                 kernel:status.kernel_result];
        return;
      }
      const uint64_t candidate = self->_capacity + self->_chunkBytes;
      const auto charged = neostation::donation::measured_ledger_delta(after, self->_baseline, candidate);
      const auto increment = neostation::donation::measured_ledger_delta(
          after, self->_chunkBaseline, self->_chunkBytes);
      self->_chunkAccountedDelta = increment.valid ? increment.resident + increment.compressed : 0;
      const uint64_t tolerance = MIN(MiB, self->_chunkBytes / 16);
      if (!charged.valid || !increment.valid || charged.resident + charged.compressed < candidate - tolerance ||
          self->_chunkAccountedDelta < self->_chunkBytes - tolerance ||
          self->_chunkAccountedDelta > self->_chunkBytes) {
        [self failStage:@"donor_incremental_kernel_accounting_proof" kernel:KERN_FAILURE];
        return;
      }
      self->_capacity = candidate;
      self->_blocks.push_back(std::move(self->_pending));
      self->_preparing = NO;
      self->_proofComplete = YES;
      [self sendUpdate];
    });
  }];
}

- (NSMutableDictionary*)metadata {
  const uint64_t index = _pending ? _blocks.size() : (_blocks.empty() ? 0 : _blocks.size() - 1);
  return [@{@"version":@2, @"nonce":_nonce ?: @"", @"generation":@(_generation),
            @"targetBytes":@(_target), @"capacityBytes":@(_capacity + (_pending ? _chunkBytes : 0)),
            @"chunkIndex":@(index), @"chunkBytes":@(_chunkBytes), @"verifiedChunkCount":@(_blocks.size()),
            @"pid":@(getpid()), @"headroom":@(_headroom),
            @"headroomAPIAvailable":@(headroomQuery() != nullptr),
            @"processHeadroomRequired":@(_processHeadroomRequired),
            @"simulator":@(TARGET_OS_SIMULATOR != 0),
            @"systemHeadroomBytes":@(_system.usable_bytes), @"systemPressure":@(static_cast<uint32_t>(_system.pressure)),
            @"effectiveEntitlements":_effectiveEntitlements ?: @{}} mutableCopy];
}

- (void)sendUpdate {
  if (_closed || _preparing || _updateInFlight || !_proofComplete) return;
  neostation::donation::Footprint current;
  auto result = neostation::donation::footprint(current);
  if (!result) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(result.stage)]
             kernel:result.kernel_result];
    return;
  }
  NSMutableDictionary* metadata = [self metadata];
  metadata[@"proofComplete"] = @YES;
  const auto charged = neostation::donation::measured_ledger_delta(current, _baseline, _capacity);
  if (!charged.valid) {
    [self failStage:@"donor_process_ledger_delta_exceeds_chunks" kernel:KERN_FAILURE];
    return;
  }
  metadata[@"residentDelta"] = @(charged.resident);
  metadata[@"compressedDelta"] = @(charged.compressed);
  metadata[@"chunkAccountedDelta"] = @(_chunkAccountedDelta);
  metadata[@"baselineNonvolatile"] = @(_baseline.nonvolatile);
  metadata[@"baselineCompressed"] = @(_baseline.nonvolatile_compressed);
  metadata[@"footprint"] = @(current.physical);
  metadata[@"nonvolatile"] = @(current.nonvolatile);
  metadata[@"compressed"] = @(current.nonvolatile_compressed);
  metadata[@"headroom"] = @(headroom());
  metadata[@"kernelResult"] = @(KERN_SUCCESS);
  const BOOL refused = _growthRefused;
  if (refused) {
    metadata[@"growthRefused"] = @YES;
    metadata[@"growthStage"] = _growthStage;
    metadata[@"refusedBytes"] = @(_refusedBytes);
  }
  _updateInFlight = YES;
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  id<NeoSwapDonorHostProtocol> host = [_connection remoteObjectProxyWithErrorHandler:^(NSError* failure) {
    (void)failure;
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  }];
  [host donorUpdate:metadata reply:^(uint64_t nextMaximum) {
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (!self) return;
    dispatch_async(self->_queue, ^{
      if (self->_closed) return;
      self->_updateInFlight = NO;
      if (refused) self->_growthRefused = NO;
      (void)neostation::donation::retry_cleanup();
      if (nextMaximum) [self prepareChunk:nextMaximum];
    });
  }];
}

- (void)failStage:(NSString*)stage kernel:(int32_t)kernelResult {
  NSMutableDictionary* metadata = [self metadata];
  metadata[@"stage"] = stage;
  metadata[@"kernelResult"] = @(kernelResult);
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  id<NeoSwapDonorHostProtocol> host = [_connection remoteObjectProxyWithErrorHandler:^(NSError* failure) {
    (void)failure;
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  }];
  [host donorFailed:metadata reply:^{
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  }];
}

- (void)finish {
  if (_closed) return;
  _closed = YES;
  if (_heartbeat) { dispatch_source_cancel(_heartbeat); _heartbeat = nil; }
  auto release = [](std::unique_ptr<neostation::donation::Block>& block) {
    if (!block) return;
    const auto released = block->reset();
    if (released) block.reset();
    else NSLog(@"NEOSWAP_DONOR_CLEANUP_PENDING stage=%s kernel=%d",
        neostation::donation::stage_name(released.stage), released.kernel_result);
  };
  release(_pending);
  for (auto& block : _blocks) release(block);
  (void)neostation::donation::retry_cleanup();
  [_connection invalidate];
  _connection = nil;
  [_context completeRequestReturningItems:nil completionHandler:nil];
  _context = nil;
}

- (void)dealloc {
  if (_heartbeat) dispatch_source_cancel(_heartbeat);
  [_connection invalidate];
}

#if defined(NEOSWAP_DONATION_PROBE)
- (void)beginProbeWithConnection:(NSXPCConnection*)connection metadata:(NSDictionary*)metadata {
  dispatch_async(_queue, ^{ [self beginWithConnection:connection metadata:metadata probe:YES]; });
}
#endif
@end
