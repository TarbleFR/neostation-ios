// SPDX-License-Identifier: MIT
#import "NeoSwapPageRelay.h"
#if __has_include("../Donation/Broker.h")
#include "../Donation/Broker.h"
#elif __has_include("Broker.h")
#include "Broker.h"
#else
#include "../neoswap-donation/Broker.h"
#endif
#import <objc/message.h>
#include <chrono>
#include <dlfcn.h>
#include <unistd.h>
#include <xpc/xpc.h>

namespace {
constexpr uint64_t segmentMaximum = 512ULL * 1024 * 1024;
#if !defined(NEOSWAP_RELAY_EXTENSION)
constexpr uint64_t capacityMaximum = 16 * segmentMaximum;
#endif
constexpr uint64_t relayAlignment = 64 * 1024;
#if !defined(NEOSWAP_RELAY_EXTENSION)
char queueKey;
using Clock = std::chrono::steady_clock;
#endif
using SetRight = void (*)(xpc_object_t, const char*, mach_port_t);
using CopyRight = mach_port_t (*)(xpc_object_t, const char*);
struct Transport {
  SetRight set = reinterpret_cast<SetRight>(dlsym(RTLD_DEFAULT, "xpc_dictionary_set_mach_send"));
  CopyRight copy = reinterpret_cast<CopyRight>(dlsym(RTLD_DEFAULT, "xpc_dictionary_copy_mach_send"));
};
const Transport& transport() { static const Transport value; return value; }
bool validSize(uint64_t size, uint64_t maximum) {
  return size >= relayAlignment && size <= maximum && size % relayAlignment == 0;
}
#if !defined(NEOSWAP_RELAY_EXTENSION)
bool numeric(NSDictionary* value, NSString* key) { return [value[key] isKindOfClass:NSNumber.class]; }
NSError* failure(NSInteger code, NSString* detail) {
  return [NSError errorWithDomain:@"NeoSwapPageRelay" code:code
                        userInfo:@{NSLocalizedDescriptionKey:detail}];
}
enum class State { idle, launching, receiving, awaitingExit, completed, failed };
#endif
}

@implementation NeoSwapPageRelayHandle {
  mach_port_t _memoryEntry;
  uint64_t _capacityBytes;
  neostation::donation::SendRight _ownedRight;
}
+ (BOOL)supportsSecureCoding { return YES; }
+ (BOOL)isTransportAvailable { return transport().set && transport().copy; }
- (instancetype)initWithMemoryEntry:(mach_port_t)entry capacityBytes:(uint64_t)bytes {
  if (!entry || !validSize(bytes, segmentMaximum) || ![self.class isTransportAvailable]) return nil;
  if ((self = [super init])) {
    if (!_ownedRight.prepare()) return nil;
    if (mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) return nil;
    if (!_ownedRight.adopt(entry)) return nil;
    _memoryEntry = entry; _capacityBytes = bytes;
  }
  return self;
}
- (instancetype)initWithCoder:(NSCoder*)coder {
  if (![coder isKindOfClass:NSXPCCoder.class] || ![self.class isTransportAvailable]) return nil;
  if ((self = [super init])) {
    xpc_object_t dictionary = [(NSXPCCoder*)coder decodeXPCObjectOfType:XPC_TYPE_DICTIONARY forKey:@"relayEntry"];
    if (!dictionary || xpc_dictionary_get_uint64(dictionary, "version") != 1) return nil;
    const uint64_t bytes = xpc_dictionary_get_uint64(dictionary, "capacityBytes");
    if (!validSize(bytes, segmentMaximum) || !_ownedRight.prepare()) return nil;
    mach_port_t entry = transport().copy(dictionary, "right");
    if (!entry || !_ownedRight.adopt(entry)) return nil;
    _memoryEntry = entry; _capacityBytes = bytes;
  }
  return self;
}
- (void)encodeWithCoder:(NSCoder*)coder {
  if (![coder isKindOfClass:NSXPCCoder.class] || ![self.class isTransportAvailable])
    [NSException raise:NSInvalidArgumentException format:@"NeoSwapPageRelayHandle requires NSXPCCoder Mach transport"];
  xpc_object_t dictionary = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(dictionary, "version", 1);
  xpc_dictionary_set_uint64(dictionary, "capacityBytes", _capacityBytes);
  transport().set(dictionary, "right", _memoryEntry);
  [(NSXPCCoder*)coder encodeXPCObject:dictionary forKey:@"relayEntry"];
}
- (mach_port_t)memoryEntry { return _memoryEntry; }
- (uint64_t)capacityBytes { return _capacityBytes; }
- (void)dealloc {
  auto status = _ownedRight.reset();
  if (!status) NSLog(@"NEOSWAP_RELAY_RIGHT_CLEANUP_PENDING stage=%s kernel=%d",
      neostation::donation::stage_name(status.stage), status.kernel_result);
}
@end

NSXPCInterface* NeoSwapPageRelayHostInterface(void) {
  NSXPCInterface* value = [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapPageRelayHostProtocol)];
  [value setClasses:[NSSet setWithObject:NeoSwapPageRelayHandle.class]
      forSelector:@selector(relayReady:metadata:reply:) argumentIndex:0 ofReply:NO];
  NSSet* metadata = [NSSet setWithObjects:NSDictionary.class, NSString.class, NSNumber.class, nil];
  [value setClasses:metadata forSelector:@selector(relayReady:metadata:reply:) argumentIndex:1 ofReply:NO];
  [value setClasses:metadata forSelector:@selector(relayFinished:reply:) argumentIndex:0 ofReply:NO];
  [value setClasses:metadata forSelector:@selector(relayFailed:reply:) argumentIndex:0 ofReply:NO];
  return value;
}

#if !defined(NEOSWAP_RELAY_EXTENSION)
// Preserve ARC's consumed-self/+1 initializer convention on the own extension.
@interface NSObject (NeoSwapPageRelayExtensionCreation)
- (nullable instancetype)_initWithPKPlugin:(id _Nonnull)plugin __attribute__((objc_method_family(init)));
@end
@interface NeoSwapPageRelaySession () <NSXPCListenerDelegate, NeoSwapPageRelayHostProtocol>
@end
@implementation NeoSwapPageRelaySession {
  NSString* _identifier;
  NSString* _nonce;
  uint64_t _requested;
  uint64_t _generation;
  uint64_t _capacity;
  NSTimeInterval _timeout;
  NeoSwapPageRelayCompletion _completion;
  State _state;
  dispatch_queue_t _queue;
  dispatch_source_t _timer;
  dispatch_source_t _exitMonitor;
  NSXPCListener* _listener;
  NSXPCConnection* _connection;
  id _extension;
  NSUUID* _requestID;
  NSUUID* _earlyEndedRequest;
  NSError* _earlyEndedError;
  int32_t _expectedPID;
  BOOL _exitMonitorRegistered;
  BOOL _exitAcknowledged;
  BOOL _creatorExitObserved;
  NSMutableArray<NeoSwapPageRelayHandle*>* _handles;
  NeoSwapPageRelayHandle* _pendingHandle;
  NSDictionary* _pendingMetadata;
  void (^_pendingReply)(BOOL);
  void (^_exitReply)(BOOL);
  NSMutableDictionary* _diagnostics;
  Clock::time_point _started;
#if defined(NEOSWAP_RELAY_PROBE)
  BOOL _probe;
#endif
}
- (instancetype)initWithHelperIdentifier:(NSString*)identifier requestedBytes:(uint64_t)bytes
    generation:(uint64_t)generation timeout:(NSTimeInterval)timeout completion:(NeoSwapPageRelayCompletion)completion {
  if ((self = [super init])) {
    _identifier = [identifier copy]; _nonce = NSUUID.UUID.UUIDString;
    _requested = bytes; _generation = generation; _timeout = MAX(1, MIN(60, timeout));
    _completion = [completion copy]; _state = State::idle;
    _queue = dispatch_queue_create("com.neogamelab.neostation.neoswap-relay", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, &queueKey, (__bridge void*)self, NULL);
    _handles = [NSMutableArray new];
    _diagnostics = [@{@"stage":@"idle", @"helperIdentifier":_identifier,
      @"requestedCapacityBytes":@(bytes), @"capacityBytes":@0, @"touchedBytes":@0,
      @"residentBytesMeasured":@NO, @"creatorExitObserved":@NO, @"retryCount":@0} mutableCopy];
  }
  return self;
}
- (NSDictionary*)requestMetadata {
  return @{@"version":@1, @"nonce":_nonce, @"generation":@(_generation),
    @"targetBytes":@(_requested), @"hostPID":@(getpid())};
}
- (BOOL)isTerminal { return _state == State::completed || _state == State::failed; }
- (void)beginTimer {
  _state = State::launching; _started = Clock::now(); _diagnostics[@"stage"] = @"launching";
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
      100 * NSEC_PER_MSEC, 10 * NSEC_PER_MSEC);
  __weak NeoSwapPageRelaySession* weak = self;
  dispatch_source_set_event_handler(_timer, ^{
    NeoSwapPageRelaySession* self = weak;
    if (!self || [self isTerminal]) return;
    if (self->_pendingHandle) [self verifyPending];
    if (std::chrono::duration<double>(Clock::now() - self->_started).count() > self->_timeout)
      [self fail:failure(4101, @"Relay launch/retention/creator-exit deadline expired")];
  });
  dispatch_resume(_timer);
}
- (void)start {
  dispatch_async(_queue, ^{
    if (self->_state != State::idle) return;
    if (!validSize(self->_requested, capacityMaximum) || !self->_generation ||
        ![NeoSwapPageRelayHandle isTransportAvailable]) {
      [self fail:failure(4102, @"Invalid relay capacity/generation or unavailable Mach transport")]; return;
    }
    Class type = NSClassFromString(@"NSExtension");
    SEL create = NSSelectorFromString(@"extensionWithIdentifier:error:");
    SEL begin = NSSelectorFromString(@"beginExtensionRequestWithInputItems:listenerEndpoint:completion:");
    SEL pluginGetter = NSSelectorFromString(@"_plugIn");
    if (!type || ![type respondsToSelector:create]) {
      [self fail:failure(4103, @"Relay NSExtension discovery API unavailable")]; return;
    }
    NSError* error = nil;
    using Create = id (*)(id, SEL, NSString*, NSError**);
    id discovered = reinterpret_cast<Create>(objc_msgSend)(type, create, self->_identifier, &error);
    if (!discovered || ![discovered respondsToSelector:pluginGetter] ||
        ![type instancesRespondToSelector:NSSelectorFromString(@"_initWithPKPlugin:")]) {
      [self fail:error ?: failure(4104, @"Independent relay extension initialization unavailable")]; return;
    }
    using Get = id (*)(id, SEL);
    id plugin = reinterpret_cast<Get>(objc_msgSend)(discovered, pluginGetter);
    if (plugin) self->_extension = [[type alloc] _initWithPKPlugin:plugin];
    if (!self->_extension || self->_extension == discovered || ![self->_extension respondsToSelector:begin] ||
        ![self->_extension respondsToSelector:NSSelectorFromString(@"pidForRequestIdentifier:")]) {
      [self fail:failure(4105, @"Relay auxiliary launch/request PID API unavailable")]; return;
    }
    self->_diagnostics[@"independentExtensionObject"] = @YES;
    self->_listener = NSXPCListener.anonymousListener; self->_listener.delegate = self; [self->_listener resume];
    [self beginTimer];
    __weak NeoSwapPageRelaySession* weak = self;
    void (^ended)(NSUUID*, NSError*) = ^(NSUUID* request, NSError* requestError) {
      NeoSwapPageRelaySession* self = weak;
      if (!self) return;
      dispatch_async(self->_queue, ^{
        if ([self isTerminal] || ![request isKindOfClass:NSUUID.class]) return;
        if (!self->_requestID) { self->_earlyEndedRequest = request; self->_earlyEndedError = requestError; return; }
        if (![request isEqual:self->_requestID]) return;
        self->_diagnostics[@"extensionRequestEnded"] = @YES;
        // An ended request is not proof that the creator process exited.
        if (self->_state != State::awaitingExit)
          [self fail:requestError ?: failure(4106, @"Relay extension ended before retention acknowledgement")];
      });
    };
    using Set = void (*)(id, SEL, id);
    SEL cancellation = NSSelectorFromString(@"setRequestCancellationBlock:");
    if ([self->_extension respondsToSelector:cancellation])
      reinterpret_cast<Set>(objc_msgSend)(self->_extension, cancellation, ended);
    SEL interruption = NSSelectorFromString(@"setRequestInterruptionBlock:");
    if ([self->_extension respondsToSelector:interruption]) {
      void (^interrupted)(NSUUID*) = ^(NSUUID* request) { ended(request, nil); };
      reinterpret_cast<Set>(objc_msgSend)(self->_extension, interruption, interrupted);
    }
    NSExtensionItem* item = [NSExtensionItem new]; item.userInfo = [self requestMetadata];
    void (^completion)(id) = ^(id request) {
      NeoSwapPageRelaySession* self = weak;
      if (!self) return;
      dispatch_async(self->_queue, ^{
        if (![request isKindOfClass:NSUUID.class]) { [self fail:failure(4107, @"Relay launch returned no request UUID")]; return; }
        self->_requestID = request;
        if ([self isTerminal]) { [self cancelRequest]; return; }
        if ([self->_earlyEndedRequest isEqual:request]) {
          [self fail:self->_earlyEndedError ?: failure(4106, @"Relay request ended before launch completion")]; return;
        }
        self->_earlyEndedRequest = nil; self->_earlyEndedError = nil;
        [self verifyPending];
      });
    };
    using Begin = void (*)(id, SEL, NSArray*, NSXPCListenerEndpoint*, id);
    reinterpret_cast<Begin>(objc_msgSend)(self->_extension, begin, @[item], self->_listener.endpoint, completion);
  });
}
- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)connection {
  __block BOOL accepted = NO;
  dispatch_sync(_queue, ^{
    if (listener != self->_listener || self->_connection || self->_state != State::launching ||
        connection.processIdentifier <= 0 || connection.processIdentifier == getpid() ||
        connection.effectiveUserIdentifier != geteuid()) return;
    self->_connection = connection; [self configureConnection:connection]; accepted = YES;
  });
  return accepted;
}
- (void)configureConnection:(NSXPCConnection*)connection {
  connection.exportedInterface = NeoSwapPageRelayHostInterface(); connection.exportedObject = self;
  __weak NeoSwapPageRelaySession* weak = self;
  void (^lost)(void) = ^{
    NeoSwapPageRelaySession* self = weak;
    if (!self) return;
    dispatch_async(self->_queue, ^{
      if ([self isTerminal]) return;
      self->_diagnostics[@"connectionEnded"] = @YES;
      if (self->_state != State::awaitingExit)
        [self fail:failure(4108, @"Relay connection ended before all rights were retained")];
      // In awaitingExit, only the kernel exit monitor may complete the session.
    });
  };
  connection.interruptionHandler = lost; connection.invalidationHandler = lost; [connection resume];
}
- (BOOL)validMetadata:(NSDictionary*)metadata source:(NSXPCConnection*)source {
  return [metadata isKindOfClass:NSDictionary.class] && source == _connection &&
    [metadata[@"version"] isEqual:@1] && [metadata[@"nonce"] isKindOfClass:NSString.class] &&
    [metadata[@"nonce"] isEqual:_nonce] && numeric(metadata, @"generation") &&
    [metadata[@"generation"] unsignedLongLongValue] == _generation && numeric(metadata, @"pid") &&
    [metadata[@"pid"] intValue] == source.processIdentifier && source.processIdentifier > 0 &&
    source.processIdentifier != getpid() && source.effectiveUserIdentifier == geteuid() &&
    numeric(metadata, @"targetBytes") && [metadata[@"targetBytes"] unsignedLongLongValue] == _requested &&
    numeric(metadata, @"segmentIndex") && numeric(metadata, @"segmentBytes") && numeric(metadata, @"capacityBytes");
}
- (void)relayReady:(NeoSwapPageRelayHandle*)handle metadata:(NSDictionary*)metadata reply:(void (^)(BOOL))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    const uint64_t expectedBytes = MIN(segmentMaximum, self->_requested - self->_capacity);
    if ((self->_state != State::launching && self->_state != State::receiving) || self->_pendingHandle ||
        ![self validMetadata:metadata source:source] || ![handle isKindOfClass:NeoSwapPageRelayHandle.class] ||
        handle.capacityBytes != expectedBytes || [metadata[@"segmentBytes"] unsignedLongLongValue] != expectedBytes ||
        [metadata[@"segmentIndex"] unsignedLongLongValue] != self->_handles.count ||
        [metadata[@"capacityBytes"] unsignedLongLongValue] != self->_capacity + expectedBytes) {
      reply(NO); [self fail:failure(4109, @"Rejected relay PID/nonce/generation/index/capacity or repeated reply")]; return;
    }
    for (NeoSwapPageRelayHandle* prior in self->_handles) if (prior.memoryEntry == handle.memoryEntry) {
      reply(NO); [self fail:failure(4110, @"Relay replayed a previously retained object")]; return;
    }
    self->_pendingHandle = handle; self->_pendingMetadata = metadata; self->_pendingReply = [reply copy];
#if defined(NEOSWAP_RELAY_PROBE)
    if (self->_probe) self->_expectedPID = source.processIdentifier;
#endif
    [self verifyPending];
  });
}
- (void)verifyPending {
  if (!_pendingHandle || !_pendingReply || [self isTerminal]) return;
  if (!_expectedPID && _extension && _requestID) {
    using GetPID = int (*)(id, SEL, id);
    _expectedPID = reinterpret_cast<GetPID>(objc_msgSend)(_extension, NSSelectorFromString(@"pidForRequestIdentifier:"), _requestID);
  }
  if (_expectedPID <= 0) { _expectedPID = 0; return; }
  if (_expectedPID == getpid() || _expectedPID != _connection.processIdentifier) {
    [self fail:failure(4111, @"Relay XPC peer differs from the launched request PID")]; return;
  }
  [_handles addObject:_pendingHandle]; _capacity += _pendingHandle.capacityBytes;
  _pendingHandle = nil; _pendingMetadata = nil; _state = State::receiving;
  _diagnostics[@"stage"] = @"retaining_named_objects";
  _diagnostics[@"retainedCapacityBytes"] = @(_capacity); _diagnostics[@"creatorPID"] = @(_expectedPID);
  auto reply = _pendingReply; _pendingReply = nil; reply(YES);
}
- (void)relayFinished:(NSDictionary*)metadata reply:(void (^)(BOOL))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    if (self->_state != State::receiving || self->_pendingHandle || self->_capacity != self->_requested ||
        ![self validMetadata:metadata source:source] || self->_expectedPID != source.processIdentifier ||
        [metadata[@"capacityBytes"] unsignedLongLongValue] != self->_requested ||
        [metadata[@"segmentIndex"] unsignedLongLongValue] != self->_handles.count ||
        [metadata[@"segmentBytes"] unsignedLongLongValue] != 0) {
      reply(NO); [self fail:failure(4112, @"Rejected relay close before complete authenticated retention")]; return;
    }
    self->_state = State::awaitingExit; self->_exitReply = [reply copy];
    self->_diagnostics[@"stage"] = @"waiting_for_creator_exit";
    self->_exitMonitor = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC,
        static_cast<uintptr_t>(self->_expectedPID), DISPATCH_PROC_EXIT, self->_queue);
    if (!self->_exitMonitor) { [self fail:failure(4113, @"Kernel creator-exit monitoring unavailable")]; return; }
    __weak NeoSwapPageRelaySession* weak = self;
    dispatch_source_set_registration_handler(self->_exitMonitor, ^{
      NeoSwapPageRelaySession* self = weak;
      if (!self || self->_state != State::awaitingExit || !self->_exitReply) return;
      self->_exitMonitorRegistered = YES; self->_exitAcknowledged = YES;
      self->_diagnostics[@"exitAcknowledged"] = @YES;
      auto finish = self->_exitReply; self->_exitReply = nil; finish(YES);
    });
    dispatch_source_set_event_handler(self->_exitMonitor, ^{
      NeoSwapPageRelaySession* self = weak;
      if (!self || self->_state != State::awaitingExit) return;
      const unsigned long events = dispatch_source_get_data(self->_exitMonitor);
      if (!self->_exitMonitorRegistered || !self->_exitAcknowledged || !(events & DISPATCH_PROC_EXIT)) {
        [self fail:failure(4114, @"Creator exited before the acknowledged retention boundary")]; return;
      }
      self->_creatorExitObserved = YES;
      self->_diagnostics[@"creatorExitObserved"] = @YES;
      self->_diagnostics[@"exitEvidence"] = @"kernel_dispatch_proc_exit";
      [self complete];
    });
    dispatch_resume(self->_exitMonitor);
  });
}
- (void)relayFailed:(NSDictionary*)metadata reply:(void (^)(void))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    reply();
    if (![self validMetadata:metadata source:source] || !numeric(metadata, @"kernelResult") ||
        ![metadata[@"stage"] isKindOfClass:NSString.class]) {
      [self fail:failure(4115, @"Rejected malformed relay failure report")]; return;
    }
    self->_diagnostics[@"kernelResult"] = metadata[@"kernelResult"];
    [self fail:failure(4116, [NSString stringWithFormat:@"Relay %@ failed (%@)", metadata[@"stage"], metadata[@"kernelResult"]])];
  });
}
- (void)___nsx_pingHost:(void (^)(void))reply { reply(); }
- (void)cancelRequest {
  SEL cancel = NSSelectorFromString(@"cancelExtensionRequestWithIdentifier:");
  if (_extension && _requestID && [_extension respondsToSelector:cancel]) {
    using Cancel = void (*)(id, SEL, id);
    reinterpret_cast<Cancel>(objc_msgSend)(_extension, cancel, _requestID);
  }
}
- (void)tearDown {
  if (_pendingReply) { _pendingReply(NO); _pendingReply = nil; }
  if (_exitReply) { _exitReply(NO); _exitReply = nil; }
  _pendingHandle = nil; _pendingMetadata = nil;
  if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
  if (_exitMonitor) { dispatch_source_cancel(_exitMonitor); _exitMonitor = nil; }
  [_connection invalidate]; _connection = nil; [_listener invalidate]; _listener = nil;
  [self cancelRequest];
}
- (void)complete {
  if (_state != State::awaitingExit || !_creatorExitObserved || _capacity != _requested) return;
  _state = State::completed; _diagnostics[@"stage"] = @"creator_exited_capacity_ready";
  _diagnostics[@"capacityBytes"] = @(_capacity); _diagnostics[@"segmentCount"] = @(_handles.count);
  NSArray* handles = [_handles copy]; [_handles removeAllObjects]; [self tearDown];
  auto completion = _completion; _completion = nil;
  if (completion) completion(handles, _expectedPID, _generation, nil);
}
- (void)fail:(NSError*)error {
  if ([self isTerminal]) return;
  _state = State::failed; _diagnostics[@"stage"] = @"failed";
  _diagnostics[@"errorDomain"] = error.domain; _diagnostics[@"errorCode"] = @(error.code);
  _diagnostics[@"technicalError"] = error.localizedDescription; _diagnostics[@"capacityBytes"] = @0;
  [self tearDown]; [_handles removeAllObjects];
  auto completion = _completion; _completion = nil;
  if (completion) completion(@[], _expectedPID, _generation, error);
}
- (void)cancel { dispatch_async(_queue, ^{ [self fail:failure(4117, @"Relay preparation cancelled")]; }); }
- (NSDictionary*)diagnostics {
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) return [_diagnostics copy];
  __block NSDictionary* value; dispatch_sync(_queue, ^{ value = [self->_diagnostics copy]; }); return value;
}
- (void)dealloc {
  if (_timer) dispatch_source_cancel(_timer);
  if (_exitMonitor) dispatch_source_cancel(_exitMonitor);
  [_connection invalidate]; [_listener invalidate]; [self cancelRequest];
}
#if defined(NEOSWAP_RELAY_PROBE)
- (void)startWithServiceNameForProbe:(NSString*)serviceName {
  dispatch_async(_queue, ^{
    if (self->_state != State::idle) return;
    if (!validSize(self->_requested, capacityMaximum) || !self->_generation) {
      [self fail:failure(4102, @"Invalid relay probe capacity/generation")]; return;
    }
    self->_probe = YES;
    self->_connection = [[NSXPCConnection alloc] initWithServiceName:serviceName];
    self->_connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(NeoSwapPageRelayProbeProtocol)];
    [self beginTimer]; [self configureConnection:self->_connection];
    id<NeoSwapPageRelayProbeProtocol> proxy = [self->_connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
      dispatch_async(self->_queue, ^{ [self fail:error]; });
    }];
    [proxy beginRelayProbe:[self requestMetadata]];
  });
}
#endif
@end

#endif // !NEOSWAP_RELAY_EXTENSION
