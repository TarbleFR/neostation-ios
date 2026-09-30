// SPDX-License-Identifier: MIT
#import "NeoSwapPageRelayHandler.h"
#import "NeoSwapPageRelay.h"
#if __has_include("../Donation/Broker.h")
#include "../Donation/Broker.h"
#elif __has_include("Broker.h")
#include "Broker.h"
#else
#include "../neoswap-donation/Broker.h"
#endif
#import <objc/message.h>
#import <objc/runtime.h>
#include <memory>
#include <vector>
#include <unistd.h>
#include <mach/mach.h>
#include <dlfcn.h>

namespace {
constexpr uint64_t maximumSegment = 512ULL * 1024 * 1024;
constexpr uint64_t maximumCapacity = 16 * maximumSegment;
constexpr uint64_t alignment = 64 * 1024;
BOOL numeric(NSDictionary* dictionary, NSString* key) { return [dictionary[key] isKindOfClass:NSNumber.class]; }
NSError* failure(NSString* detail) {
  return [NSError errorWithDomain:@"NeoSwapPageRelay" code:4201 userInfo:@{NSLocalizedDescriptionKey:detail}];
}
}
@implementation NeoSwapPageRelayContext
+ (NSXPCInterface*)_extensionAuxiliaryHostProtocol { return NeoSwapPageRelayHostInterface(); }
+ (NSXPCInterface*)_extensionAuxiliaryVendorProtocol {
  return [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapPageRelayVendorProtocol)];
}
@end

@implementation NeoSwapPageRelayHandler {
  dispatch_queue_t _queue;
  dispatch_source_t _deadline;
  NSExtensionContext* _context;
  NSXPCConnection* _connection;
  NSString* _nonce;
  uint64_t _generation;
  uint64_t _target;
  uint64_t _capacity;
  uint64_t _index;
  BOOL _closed;
  BOOL _awaitingExitAck;
  BOOL _ownHelperProcess;
  std::vector<std::unique_ptr<neostation::donation::SendRight>> _rights;
}
- (instancetype)init {
  if ((self = [super init]))
    _queue = dispatch_queue_create("com.neogamelab.neostation.neoswap-relay-helper", DISPATCH_QUEUE_SERIAL);
  return self;
}
- (void)beginRequestWithExtensionContext:(NSExtensionContext*)context {
  dispatch_async(_queue, ^{
    if (self->_context || self->_connection || self->_closed) {
      [context cancelRequestWithError:failure(@"Relay helper already has a request")]; return;
    }
    self->_context = context;
    NSString* identifier = NSBundle.mainBundle.bundleIdentifier;
    // Never exit the app or a pre-existing v1 donor/JIT extension. The packaged
    // principal/context and own bundle marker must match this dedicated helper.
    self->_ownHelperProcess = [identifier hasSuffix:@".NeoSwapPageRelay"] &&
      [[NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoStationNeoSwapPageRelay"] isEqual:@"1"];
    SEL selector = NSSelectorFromString(@"_auxiliaryConnection");
    if (!self->_ownHelperProcess || ![context respondsToSelector:selector]) {
      [self finish:failure(@"Dedicated relay process/auxiliary connection unavailable")]; return;
    }
    using Get = id (*)(id, SEL);
    id candidate = reinterpret_cast<Get>(objc_msgSend)(context, selector);
    if (![candidate isKindOfClass:NSXPCConnection.class]) {
      [self finish:failure(@"Relay context supplied no auxiliary connection")]; return;
    }
    NSXPCConnection* connection = candidate;
    Protocol* host = connection.remoteObjectInterface.protocol;
    Protocol* vendor = connection.exportedInterface.protocol;
    if (![context isKindOfClass:NeoSwapPageRelayContext.class] || !host || !vendor ||
        !protocol_conformsToProtocol(host, @protocol(NeoSwapPageRelayHostProtocol)) ||
        !protocol_isEqual(vendor, @protocol(NeoSwapPageRelayVendorProtocol))) {
      [self finish:failure(@"Relay auxiliary interfaces were not configured before request decoding")]; return;
    }
    id item = context.inputItems.firstObject;
    [self beginWithConnection:connection metadata:[item isKindOfClass:NSExtensionItem.class] ? [item userInfo] : nil];
  });
}
- (void)beginWithConnection:(NSXPCConnection*)connection metadata:(NSDictionary*)metadata {
  if (_closed || _connection || !_ownHelperProcess || ![metadata isKindOfClass:NSDictionary.class] ||
      ![metadata[@"version"] isEqual:@1] || ![metadata[@"nonce"] isKindOfClass:NSString.class] ||
      [metadata[@"nonce"] length] < 16 || [metadata[@"nonce"] length] > 128 ||
      !numeric(metadata, @"generation") || ![metadata[@"generation"] unsignedLongLongValue] ||
      !numeric(metadata, @"targetBytes") || !numeric(metadata, @"hostPID") ||
      [metadata[@"hostPID"] intValue] != connection.processIdentifier || connection.processIdentifier <= 0 ||
      connection.processIdentifier == getpid() || connection.effectiveUserIdentifier != geteuid()) {
    [connection invalidate]; [self finish:failure(@"Invalid relay nonce/generation/authenticated host PID")]; return;
  }
  _connection = connection; _nonce = [metadata[@"nonce"] copy];
  _generation = [metadata[@"generation"] unsignedLongLongValue]; _target = [metadata[@"targetBytes"] unsignedLongLongValue];
  _connection.remoteObjectInterface = NeoSwapPageRelayHostInterface();
  __weak NeoSwapPageRelayHandler* weak = self;
  void (^lost)(void) = ^{
    NeoSwapPageRelayHandler* self = weak;
    if (self) dispatch_async(self->_queue, ^{ [self finish:failure(@"Relay host connection ended")]; });
  };
  _connection.invalidationHandler = lost; _connection.interruptionHandler = lost;
  if (_target < alignment || _target > maximumCapacity || _target % alignment ||
      ![NeoSwapPageRelayHandle isTransportAvailable]) {
    [self failStage:@"requested_capacity" kernel:KERN_INVALID_ARGUMENT]; return;
  }
  // A silent host cannot leave a request indefinitely holding memory entries.
  _deadline = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_deadline, dispatch_time(DISPATCH_TIME_NOW, 65 * NSEC_PER_SEC),
      DISPATCH_TIME_FOREVER, 0);
  dispatch_source_set_event_handler(_deadline, ^{
    NeoSwapPageRelayHandler* self = weak;
    if (self) [self finish:failure(@"Relay retention acknowledgement deadline expired")];
  });
  dispatch_resume(_deadline);
  [self issueNext];
}
- (NSDictionary*)metadataForBytes:(uint64_t)bytes {
  return @{@"version":@1, @"nonce":_nonce, @"generation":@(_generation), @"pid":@(getpid()),
    @"targetBytes":@(_target), @"capacityBytes":@(_capacity), @"segmentIndex":@(_index), @"segmentBytes":@(bytes)};
}
- (id<NeoSwapPageRelayHostProtocol>)proxy {
  __weak NeoSwapPageRelayHandler* weak = self;
  return [_connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
    NeoSwapPageRelayHandler* self = weak;
    if (self) dispatch_async(self->_queue, ^{ [self finish:error]; });
  }];
}
- (void)issueNext {
  if (_closed || _awaitingExitAck) return;
  if (_capacity == _target) { [self requestExit]; return; }
  // Keep this optional entry-creation API out of dyld's eager imports. The
  // dedicated helper reports a normal preparation failure when unavailable.
  static const auto createEntry = reinterpret_cast<decltype(&mach_make_memory_entry_64)>(
      dlsym(RTLD_DEFAULT, "mach_make_memory_entry_64"));
  if (!createEntry) { [self failStage:@"memory_entry_api_unavailable" kernel:KERN_NOT_SUPPORTED]; return; }
  const uint64_t bytes = MIN(maximumSegment, _target - _capacity);
  auto right = std::make_unique<neostation::donation::SendRight>();
  const auto prepared = right->prepare();
  if (!prepared) { [self failStage:@"reserve_right_cleanup" kernel:prepared.kernel_result]; return; }
  memory_object_size_t size = bytes;
  mach_port_t entry = MACH_PORT_NULL;
  // As in Guest Page Relay: create a ledger-tagged named object without a donor
  // mapping or fake page touch. Capacity is not reported as resident memory.
  const vm_prot_t permissions = VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_NAMED_CREATE | MAP_MEM_LEDGER_TAGGED;
  kern_return_t kr = createEntry(mach_task_self(), &size, 0, permissions, &entry, MACH_PORT_NULL);
  if (entry != MACH_PORT_NULL) (void)right->adopt(entry);
  if (kr != KERN_SUCCESS || size != bytes || entry == MACH_PORT_NULL) {
    [self failStage:@"create_ledger_tagged_entry" kernel:kr == KERN_SUCCESS ? KERN_INVALID_ARGUMENT : kr]; return;
  }
  NeoSwapPageRelayHandle* handle = [[NeoSwapPageRelayHandle alloc] initWithMemoryEntry:entry capacityBytes:bytes];
  if (!handle) { [self failStage:@"retain_transport_right" kernel:KERN_RESOURCE_SHORTAGE]; return; }
  _rights.push_back(std::move(right)); _capacity += bytes;
  NSDictionary* metadata = [self metadataForBytes:bytes];
  __weak NeoSwapPageRelayHandler* weak = self;
  [[self proxy] relayReady:handle metadata:metadata reply:^(BOOL retained) {
    NeoSwapPageRelayHandler* self = weak;
    if (!self) return;
    dispatch_async(self->_queue, ^{
      if (self->_closed) return;
      if (!retained) { [self finish:failure(@"Host rejected relay object retention")]; return; }
      ++self->_index; [self issueNext];
    });
  }];
}
- (void)requestExit {
  if (_closed || _awaitingExitAck || _capacity != _target || !_ownHelperProcess) return;
  _awaitingExitAck = YES;
  __weak NeoSwapPageRelayHandler* weak = self;
  [[self proxy] relayFinished:[self metadataForBytes:0] reply:^(BOOL mayExit) {
    NeoSwapPageRelayHandler* self = weak;
    if (!self) return;
    dispatch_async(self->_queue, ^{
      if (self->_closed) return;
      if (!mayExit) { [self finish:failure(@"Host refused relay creator exit")]; return; }
      // The authenticated host has retained every right and armed a kernel
      // process-exit monitor. Exit this dedicated creator process only; its
      // named objects survive in the host. No process is killed by PID.
      if (self->_ownHelperProcess && self->_awaitingExitAck && self->_capacity == self->_target) _exit(0);
    });
  }];
}
- (void)failStage:(NSString*)stage kernel:(kern_return_t)kernel {
  if (_closed) return;
  NSMutableDictionary* metadata = [[self metadataForBytes:0] mutableCopy];
  metadata[@"stage"] = stage; metadata[@"kernelResult"] = @(kernel);
  [[self proxy] relayFailed:metadata reply:^{}];
  [self finish:failure([NSString stringWithFormat:@"Relay %@ failed (%d)", stage, kernel])];
}
- (void)finish:(NSError*)error {
  if (_closed) return;
  _closed = YES;
  if (_deadline) { dispatch_source_cancel(_deadline); _deadline = nil; }
  _rights.clear();
  [_context cancelRequestWithError:error]; _context = nil;
  [_connection invalidate]; _connection = nil;
  (void)neostation::donation::retry_cleanup();
}
- (void)dealloc {
  if (_deadline) dispatch_source_cancel(_deadline);
  [_connection invalidate];
}
#if defined(NEOSWAP_RELAY_PROBE)
- (void)beginProbeWithConnection:(NSXPCConnection*)connection metadata:(NSDictionary*)metadata {
  dispatch_async(_queue, ^{
    self->_ownHelperProcess = [[NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoSwapRelayProbeService"] isEqual:@YES] &&
      [NSBundle.mainBundle.bundleIdentifier hasSuffix:@".NeoSwapPageRelay"];
    [self beginWithConnection:connection metadata:metadata];
  });
}
#endif
@end
