#import "NeoSwapDonorRequestHandler.h"
#import "NeoSwapDonorIPC.h"
#include "Broker.h"

#import <objc/message.h>
#include <dlfcn.h>
#include <cstring>
#include <memory>
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
struct LedgerDelta { uint64_t resident; uint64_t compressed; bool valid; };
LedgerDelta measuredDelta(const neostation::donation::Footprint& current,
                          const neostation::donation::Footprint& baseline, uint64_t capacity) {
  // TASK_VM_INFO fields are process-wide. This dedicated helper creates one
  // known object, and only its ledger increase (bounded by that entry) is shown.
  const uint64_t resident = current.nonvolatile > baseline.nonvolatile
      ? current.nonvolatile - baseline.nonvolatile : 0;
  const uint64_t compressed = current.nonvolatile_compressed > baseline.nonvolatile_compressed
      ? current.nonvolatile_compressed - baseline.nonvolatile_compressed : 0;
  const bool valid = resident <= capacity && compressed <= capacity &&
                     resident <= capacity - compressed;
  return {resident, compressed, valid};
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

@implementation NeoSwapDonorRequestHandler {
  dispatch_queue_t _queue;
  dispatch_source_t _heartbeat;
  NSExtensionContext* _context;
  NSXPCConnection* _connection;
  NSString* _nonce;
  uint64_t _generation;
  uint64_t _capacity;
  uint64_t _headroom;
  BOOL _proofComplete;
  BOOL _closed;
  std::unique_ptr<neostation::donation::Block> _block;
  neostation::donation::Footprint _baseline;
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
    id item = context.inputItems.firstObject;
    NSDictionary* metadata = [item isKindOfClass:NSExtensionItem.class] ? [item userInfo] : nil;
    [self beginWithConnection:connection metadata:metadata probe:NO];
  });
}

- (void)beginWithConnection:(NSXPCConnection*)connection
                   metadata:(NSDictionary*)metadata probe:(BOOL)probe {
  if (_closed || _connection || ![metadata isKindOfClass:NSDictionary.class] ||
      ![metadata[@"version"] isEqual:@1] ||
      ![metadata[@"nonce"] isKindOfClass:NSString.class] ||
      [metadata[@"nonce"] length] < 16 || [metadata[@"nonce"] length] > 128 ||
      !numeric(metadata, @"generation") || ![metadata[@"generation"] unsignedLongLongValue] ||
      !numeric(metadata, @"capacityBytes") || !numeric(metadata, @"hostPID") ||
      [metadata[@"hostPID"] intValue] <= 0 ||
      [metadata[@"hostPID"] intValue] != connection.processIdentifier ||
      connection.processIdentifier == getpid()) {
    [_context cancelRequestWithError:error(@"Invalid donor request nonce/generation/host process")];
    _context = nil;
    [connection invalidate];
    _closed = YES;
    return;
  }
  _connection = connection;
  _effectiveEntitlements = effectiveEntitlements();
  _nonce = [metadata[@"nonce"] copy];
  _generation = [metadata[@"generation"] unsignedLongLongValue];
  uint64_t requested = [metadata[@"capacityBytes"] unsignedLongLongValue];
  _capacity = requested;
  _connection.remoteObjectInterface = NeoSwapDonorHostInterface();
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  // Only this private auxiliary connection is configured. No Foundation classes
  // or global codec behavior are changed, and no app-group container is needed.
  void (^lost)(void) = ^{
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  };
  _connection.invalidationHandler = lost;
  _connection.interruptionHandler = lost;

  if (!requested || requested > 256 * MiB || requested % vm_page_size) {
    [self failStage:@"requested_size" kernel:KERN_INVALID_ARGUMENT];
    return;
  }
  _headroom = headroom();
  if (!probe) {
    if (!headroomQuery()) {
      [self failStage:@"headroom_api_unavailable" kernel:KERN_NOT_SUPPORTED];
      return;
    }
    // Sharing extensions can have a much smaller jetsam budget than the app.
    // Entitlements requested by a signer are not treated as granted headroom.
    const uint64_t maximum = MIN(requested, 64 * MiB);
    _capacity = _headroom > 16 * MiB ? MIN(maximum, _headroom - 16 * MiB) : 0;
    _capacity -= _capacity % vm_page_size;
    if (_capacity < MiB) {
      [self failStage:@"insufficient_donor_headroom" kernel:KERN_RESOURCE_SHORTAGE];
      return;
    }
  }
  auto measured = neostation::donation::footprint(_baseline);
  if (!measured) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(measured.stage)]
             kernel:measured.kernel_result];
    return;
  }
  _block = std::make_unique<neostation::donation::Block>();
  auto allocated = neostation::donation::Block::create_owned(_capacity, *_block);
  if (!allocated) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(allocated.stage)]
             kernel:allocated.kernel_result];
    return;
  }
  const uint64_t pattern = NeoSwapDonorPattern(_nonce, _generation, NO);
  auto bytes = static_cast<unsigned char*>(_block->data());
  for (uint64_t offset = 0; offset < _capacity; offset += vm_page_size)
    std::memcpy(bytes + offset, &pattern, sizeof(pattern));
  NeoSwapMachHandle* handle = [[NeoSwapMachHandle alloc] initWithMemoryEntry:_block->entry()
                                                            capacityBytes:_capacity];
  if (!handle) { [self failStage:@"mach_right_transport" kernel:KERN_NOT_SUPPORTED]; return; }
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
      const uint64_t expected = NeoSwapDonorPattern(self->_nonce, self->_generation, YES);
      auto bytes = static_cast<unsigned char*>(self->_block->data());
      for (uint64_t offset = 0; offset < self->_capacity; offset += vm_page_size) {
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
      const auto charged = measuredDelta(after, self->_baseline, self->_capacity);
      const uint64_t tolerance = MIN(MiB, self->_capacity / 16);
      if (!charged.valid || charged.resident + charged.compressed < self->_capacity - tolerance) {
        [self failStage:@"donor_kernel_accounting_proof" kernel:KERN_FAILURE];
        return;
      }
      self->_proofComplete = YES;
      [self sendUpdate];
      self->_heartbeat = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self->_queue);
      dispatch_source_set_timer(self->_heartbeat, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                               NSEC_PER_SEC, NSEC_PER_SEC / 10);
      dispatch_source_set_event_handler(self->_heartbeat, ^{
        NeoSwapDonorRequestHandler* self = weakSelf;
        if (self && !self->_closed) [self sendUpdate];
      });
      dispatch_resume(self->_heartbeat);
    });
  }];
}

- (NSMutableDictionary*)metadata {
  return [@{@"version":@1, @"nonce":_nonce ?: @"", @"generation":@(_generation),
            @"capacityBytes":@(_capacity), @"pid":@(getpid()),
            @"headroom":@(_headroom), @"headroomAPIAvailable":@(headroomQuery() != nullptr),
            @"effectiveEntitlements":_effectiveEntitlements ?: @{}} mutableCopy];
}

- (void)sendUpdate {
  neostation::donation::Footprint current;
  auto result = neostation::donation::footprint(current);
  if (!result) {
    [self failStage:[NSString stringWithUTF8String:neostation::donation::stage_name(result.stage)]
             kernel:result.kernel_result];
    return;
  }
  NSMutableDictionary* metadata = [self metadata];
  metadata[@"proofComplete"] = @(_proofComplete);
  const auto charged = measuredDelta(current, _baseline, _capacity);
  if (!charged.valid) {
    [self failStage:@"donor_process_ledger_delta_exceeds_entry" kernel:KERN_FAILURE];
    return;
  }
  metadata[@"residentDelta"] = @(charged.resident);
  metadata[@"compressedDelta"] = @(charged.compressed);
  metadata[@"baselineNonvolatile"] = @(_baseline.nonvolatile);
  metadata[@"baselineCompressed"] = @(_baseline.nonvolatile_compressed);
  metadata[@"footprint"] = @(current.physical);
  metadata[@"nonvolatile"] = @(current.nonvolatile);
  metadata[@"compressed"] = @(current.nonvolatile_compressed);
  metadata[@"headroom"] = @(headroom());
  metadata[@"kernelResult"] = @(KERN_SUCCESS);
  __weak NeoSwapDonorRequestHandler* weakSelf = self;
  id<NeoSwapDonorHostProtocol> host = [_connection remoteObjectProxyWithErrorHandler:^(NSError* failure) {
    (void)failure;
    NeoSwapDonorRequestHandler* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{ [self finish]; });
  }];
  [host donorUpdate:metadata];
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
  if (_block) {
    const auto released = _block->reset();
    if (released) _block.reset();
    else NSLog(@"NEOSWAP_DONOR_CLEANUP_PENDING stage=%s kernel=%d",
        neostation::donation::stage_name(released.stage), released.kernel_result);
    // On failure, retain the block for retry/destructor quarantine; never
    // substitute a successful cleanup report for a failed Mach operation.
  }
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
