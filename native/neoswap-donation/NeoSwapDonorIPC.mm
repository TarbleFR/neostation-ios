#import "NeoSwapDonorIPC.h"
#include "Broker.h"

#import <objc/message.h>
#include <chrono>
#include <cstring>
#include <memory>
#include <unistd.h>

namespace {
char queueKey;
using Clock = std::chrono::steady_clock;
NSError* failure(NSInteger code, NSString* detail) {
  return [NSError errorWithDomain:@"NeoSwapDonation" code:code
                        userInfo:@{NSLocalizedDescriptionKey:detail}];
}
BOOL number(NSDictionary* input, NSString* key) {
  return [input[key] isKindOfClass:NSNumber.class];
}
}

// These private selectors are discovered on the own extension only. Declaring
// the initializer's method family preserves ARC's consumed-self/+1 contract.
@interface NSObject (NeoSwapDonorExtensionCreation)
- (nullable instancetype)_initWithPKPlugin:(id _Nonnull)plugin
    __attribute__((objc_method_family(init)));
@end

@interface NeoSwapDonorSession () <NSXPCListenerDelegate, NeoSwapDonorHostProtocol>
@end

@implementation NeoSwapDonorSession {
  NSString* _identifier;
  NSString* _nonce;
  uint64_t _requested;
  uint64_t _initialMaximum;
  NSTimeInterval _timeout;
  NeoSwapDonorObserver _observer;
  dispatch_queue_t _queue;
  dispatch_source_t _timer;
  NSXPCListener* _listener;
  NSXPCConnection* _connection;
  id _extension;
  NSUUID* _requestID;
  NSUUID* _earlyEndedRequest;
  NSError* _earlyEndedError;
  int32_t _expectedPID;
  NeoSwapDonorSnapshot _snapshot;
  NSMutableArray<NeoSwapMachHandle*>* _handles;
  NeoSwapMachHandle* _handle;
  std::unique_ptr<neostation::donation::Block> _proof;
  void (^_pendingReply)(BOOL);
  NSDictionary* _pendingMetadata;
  NSMutableDictionary* _diagnostics;
  uint64_t _acknowledgedChunks;
  uint64_t _nextMaximum;
  uint64_t _inFlightMaximum;
  uint64_t _beforeChunkAccounted;
  Clock::time_point _chunkStarted;
  Clock::time_point _started;
  Clock::time_point _lastUpdate;
#if defined(NEOSWAP_DONATION_PROBE)
  BOOL _probe;
#endif
}

- (instancetype)initWithHelperIdentifier:(NSString*)identifier
                           requestedBytes:(uint64_t)bytes
                               generation:(uint64_t)generation
                                  timeout:(NSTimeInterval)timeout
                                 observer:(NeoSwapDonorObserver)observer {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _nonce = NSUUID.UUID.UUIDString;
    _requested = bytes;
    _initialMaximum = MIN(bytes, 64ULL * 1024 * 1024);
    _timeout = MAX(1, MIN(60, timeout));
    _observer = [observer copy];
    _queue = dispatch_queue_create("com.neogamelab.neostation.neoswap-donor", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_queue, &queueKey, (__bridge void*)self, NULL);
    _snapshot.generation = generation;
    _snapshot.targetBytes = bytes;
    _snapshot.state = NeoSwapDonorStateIdle;
    _handles = [NSMutableArray new];
    _diagnostics = [@{@"stage":@"idle", @"helperIdentifier":_identifier,
                     @"requestedBytes":@(bytes)} mutableCopy];
  }
  return self;
}

- (NSDictionary*)requestMetadata {
  return @{ @"version":@2, @"nonce":_nonce, @"generation":@(_snapshot.generation),
            @"targetBytes":@(_requested),
            @"initialMaximumBytes":@(_initialMaximum),
            @"hostPID":@(getpid()) };
}

- (void)notify:(NSError*)error {
  if (_observer) _observer(self, _snapshot, error);
}

- (void)beginTimer {
  _snapshot.state = NeoSwapDonorStateLaunching;
  _diagnostics[@"stage"] = @"launching";
  _started = _lastUpdate = Clock::now();
  _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
  dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                           NSEC_PER_SEC, NSEC_PER_SEC / 10);
  __weak NeoSwapDonorSession* weakSelf = self;
  dispatch_source_set_event_handler(_timer, ^{
    NeoSwapDonorSession* self = weakSelf;
    if (!self) return;
    const auto now = Clock::now();
    if (self->_snapshot.state == NeoSwapDonorStateLaunching && self->_handle && self->_requestID)
      [self verifyPending];
    if (self->_snapshot.state != NeoSwapDonorStateActive &&
        std::chrono::duration<double>(now - self->_started).count() > self->_timeout) {
      [self fail:failure(3101, @"Donor launch/shared-page verification timed out")];
    } else if (self->_snapshot.state == NeoSwapDonorStateActive &&
               self->_snapshot.growthState == NeoSwapDonorGrowthPreparing &&
               std::chrono::duration<double>(now - self->_chunkStarted).count() > self->_timeout) {
      [self fail:failure(3120, @"Donor chunk preparation/shared-page verification timed out")];
    } else if (self->_snapshot.state == NeoSwapDonorStateActive &&
               self->_snapshot.growthState != NeoSwapDonorGrowthPreparing &&
               std::chrono::duration<double>(now - self->_lastUpdate).count() > 6) {
      [self fail:failure(3102, @"Donor ledger heartbeat expired")];
    }
  });
  dispatch_resume(_timer);
}

- (void)start {
  dispatch_async(_queue, ^{
    if (self->_snapshot.state != NeoSwapDonorStateIdle) return;
    if (!self->_snapshot.generation || self->_requested < 1024 * 1024 ||
        self->_requested > 8ULL * 1024 * 1024 * 1024 ||
        self->_requested % vm_page_size ||
        ![NeoSwapMachHandle isTransportAvailable]) {
      [self fail:failure(3103, @"Invalid donor size/generation or unavailable Mach-right transport")];
      return;
    }
    Class extensionClass = NSClassFromString(@"NSExtension");
    SEL create = NSSelectorFromString(@"extensionWithIdentifier:error:");
    SEL begin = NSSelectorFromString(@"beginExtensionRequestWithInputItems:listenerEndpoint:completion:");
    if (!extensionClass || ![extensionClass respondsToSelector:create]) {
      [self fail:failure(3104, @"NSExtension launch API unavailable")];
      return;
    }
    NSError* error = nil;
    using Create = id (*)(id, SEL, NSString*, NSError**);
    id discovered = reinterpret_cast<Create>(objc_msgSend)(extensionClass, create,
                                                          self->_identifier, &error);
    SEL pluginGetter = NSSelectorFromString(@"_plugIn");
    SEL initialize = NSSelectorFromString(@"_initWithPKPlugin:");
    if (!discovered || ![discovered respondsToSelector:pluginGetter] ||
        ![extensionClass instancesRespondToSelector:initialize]) {
      [self fail:error ?: failure(3121, @"Independent donor extension initialization API unavailable")];
      return;
    }
    using GetPlugin = id (*)(id, SEL);
    id plugin = reinterpret_cast<GetPlugin>(objc_msgSend)(discovered, pluginGetter);
    if (plugin) self->_extension = [[extensionClass alloc] _initWithPKPlugin:plugin];
    if (!self->_extension || ![self->_extension respondsToSelector:begin] ||
        self->_extension == discovered ||
        ![self->_extension respondsToSelector:NSSelectorFromString(@"pidForRequestIdentifier:")]) {
      [self fail:error ?: failure(3105, @"Donor extension/auxiliary launch/PID API unavailable")];
      return;
    }
    self->_diagnostics[@"independentExtensionObject"] = @YES;
    self->_listener = NSXPCListener.anonymousListener;
    self->_listener.delegate = self;
    [self->_listener resume];
    [self beginTimer];
    __weak NeoSwapDonorSession* weakSelf = self;
    void (^ended)(NSUUID*, NSError*) = ^(NSUUID* request, NSError* requestError) {
      NeoSwapDonorSession* self = weakSelf;
      if (self) dispatch_async(self->_queue, ^{
        if (![request isKindOfClass:NSUUID.class] ||
            self->_snapshot.state == NeoSwapDonorStateClosed ||
            self->_snapshot.state == NeoSwapDonorStateFailed) return;
        if (!self->_requestID) {
          self->_earlyEndedRequest = request;
          self->_earlyEndedError = requestError;
          return;
        }
        if (![request isEqual:self->_requestID]) return;
        [self fail:requestError ?: failure(3106, @"Donor extension request ended")];
      });
    };
    // Only the independently initialized object receives these callbacks.
    // Cancellation and interruption have different block arities.
    using Set = void (*)(id, SEL, id);
    SEL cancellation = NSSelectorFromString(@"setRequestCancellationBlock:");
    if ([self->_extension respondsToSelector:cancellation])
      reinterpret_cast<Set>(objc_msgSend)(self->_extension, cancellation, ended);
    SEL interruption = NSSelectorFromString(@"setRequestInterruptionBlock:");
    if ([self->_extension respondsToSelector:interruption]) {
      void (^interrupted)(NSUUID*) = ^(NSUUID* request) { ended(request, nil); };
      reinterpret_cast<Set>(objc_msgSend)(self->_extension, interruption, interrupted);
    }
    NSExtensionItem* item = [NSExtensionItem new];
    item.userInfo = [self requestMetadata];
    void (^completion)(id) = ^(id request) {
      NeoSwapDonorSession* self = weakSelf;
      if (!self) return;
      dispatch_async(self->_queue, ^{
        if (![request isKindOfClass:NSUUID.class]) {
          [self fail:failure(3122, @"Donor extension did not return a request UUID")];
          return;
        }
        self->_requestID = request;
        if (self->_snapshot.state == NeoSwapDonorStateClosed ||
            self->_snapshot.state == NeoSwapDonorStateFailed) {
          [self cancelRequest];
          return;
        }
        if ([self->_earlyEndedRequest isEqual:self->_requestID]) {
          [self fail:self->_earlyEndedError ?: failure(3106, @"Donor extension request ended before launch completion")];
          return;
        }
        self->_earlyEndedRequest = nil;
        self->_earlyEndedError = nil;
        using GetPID = int (*)(id, SEL, id);
        self->_expectedPID = reinterpret_cast<GetPID>(objc_msgSend)(self->_extension,
            NSSelectorFromString(@"pidForRequestIdentifier:"), request);
        if (self->_expectedPID == getpid()) {
          [self fail:failure(3107, @"Donor extension PID was not a separate verified process")];
          return;
        }
        [self verifyPending];
      });
    };
    using Begin = void (*)(id, SEL, NSArray*, NSXPCListenerEndpoint*, id);
    reinterpret_cast<Begin>(objc_msgSend)(self->_extension, begin, @[item],
                                         self->_listener.endpoint, completion);
  });
}

- (BOOL)listener:(NSXPCListener*)listener shouldAcceptNewConnection:(NSXPCConnection*)connection {
  __block BOOL accept = NO;
  dispatch_sync(_queue, ^{
    if (listener != self->_listener || self->_connection ||
        self->_snapshot.state != NeoSwapDonorStateLaunching ||
        connection.processIdentifier <= 0 || connection.processIdentifier == getpid() ||
        connection.effectiveUserIdentifier != geteuid()) return;
    self->_connection = connection;
    [self configureConnection:connection];
    accept = YES;
  });
  return accept;
}

- (void)configureConnection:(NSXPCConnection*)connection {
  connection.exportedInterface = NeoSwapDonorHostInterface();
  connection.exportedObject = self;
  __weak NeoSwapDonorSession* weakSelf = self;
  void (^lost)(void) = ^{
    NeoSwapDonorSession* self = weakSelf;
    if (self) dispatch_async(self->_queue, ^{
      if (self->_snapshot.state != NeoSwapDonorStateClosed &&
          self->_snapshot.state != NeoSwapDonorStateFailed)
        [self fail:failure(3108, @"Donor XPC connection was interrupted or invalidated")];
    });
  };
  connection.interruptionHandler = lost;
  connection.invalidationHandler = lost;
  [connection resume];
}

- (BOOL)validMetadata:(NSDictionary*)metadata source:(NSXPCConnection*)source {
  return [metadata isKindOfClass:NSDictionary.class] && source == _connection &&
      [metadata[@"version"] isEqual:@2] &&
      [metadata[@"nonce"] isKindOfClass:NSString.class] &&
      [metadata[@"nonce"] isEqual:_nonce] && number(metadata, @"generation") &&
      [metadata[@"generation"] unsignedLongLongValue] == _snapshot.generation &&
      number(metadata, @"pid") && [metadata[@"pid"] intValue] == source.processIdentifier &&
      source.processIdentifier > 0 && source.processIdentifier != getpid() &&
      number(metadata, @"targetBytes") &&
      [metadata[@"targetBytes"] unsignedLongLongValue] == _requested &&
      number(metadata, @"capacityBytes") &&
      [metadata[@"capacityBytes"] unsignedLongLongValue] <= _requested &&
      number(metadata, @"chunkIndex") && number(metadata, @"chunkBytes") &&
      number(metadata, @"verifiedChunkCount");
}

- (void)donorReady:(NeoSwapMachHandle*)handle metadata:(NSDictionary*)metadata
            reply:(void (^)(BOOL))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    if (![metadata isKindOfClass:NSDictionary.class]) {
      reply(NO);
      [self fail:failure(3109, @"Rejected a non-dictionary donor ready report")];
      return;
    }
    const uint64_t chunkIndex = [metadata[@"chunkIndex"] unsignedLongLongValue];
    const uint64_t chunkBytes = [metadata[@"chunkBytes"] unsignedLongLongValue];
    if ((self->_snapshot.state != NeoSwapDonorStateLaunching &&
         (self->_snapshot.state != NeoSwapDonorStateActive ||
          self->_snapshot.growthState != NeoSwapDonorGrowthPreparing)) || self->_handle ||
        ![self validMetadata:metadata source:source] || handle.capacityBytes < 1024 * 1024 ||
        handle.capacityBytes > (self->_handles.count ? self->_inFlightMaximum : self->_initialMaximum) ||
        handle.capacityBytes != chunkBytes || chunkIndex != self->_handles.count ||
        [metadata[@"verifiedChunkCount"] unsignedLongLongValue] != self->_handles.count ||
        [metadata[@"capacityBytes"] unsignedLongLongValue] != self->_snapshot.capacityBytes + chunkBytes) {
      reply(NO);
      [self fail:failure(3109, @"Rejected donor PID/nonce/generation/size or repeated ready message")];
      return;
    }
    for (NeoSwapMachHandle* prior in self->_handles) {
      // All preceding rights are retained, so an identical receive-side name
      // denotes a replay of an existing named object, not a new donation.
      if (prior.memoryEntry == handle.memoryEntry) {
        reply(NO);
        [self fail:failure(3121, @"A donor replayed a previously verified memory entry")];
        return;
      }
    }
    self->_handle = handle;
    self->_pendingMetadata = metadata;
    self->_pendingReply = [reply copy];
    self->_diagnostics[@"pendingChunkIndex"] = @(chunkIndex);
    self->_diagnostics[@"pendingChunkBytes"] = @(chunkBytes);
    self->_beforeChunkAccounted = self->_snapshot.donatedResidentBytes +
                                  self->_snapshot.donatedCompressedBytes;
    self->_chunkStarted = Clock::now();
#if defined(NEOSWAP_DONATION_PROBE)
    if (self->_probe) self->_expectedPID = source.processIdentifier;
#endif
    [self verifyPending];
  });
}

- (void)verifyPending {
  if (!_handle || !_pendingReply) return;
  if (!_expectedPID && _extension && _requestID) {
    using GetPID = int (*)(id, SEL, id);
    _expectedPID = reinterpret_cast<GetPID>(objc_msgSend)(_extension,
        NSSelectorFromString(@"pidForRequestIdentifier:"), _requestID);
  }
  // The request identifier can arrive before the plugin's PID is published.
  // Keep the nonce-bound ready message pending until the same launch deadline.
  if (_expectedPID <= 0) { _expectedPID = 0; return; }
  if (_expectedPID != _connection.processIdentifier) {
    [self fail:failure(3110, @"XPC peer PID differs from the launched extension request PID")];
    return;
  }
  _proof = std::make_unique<neostation::donation::Block>();
  const auto result = neostation::donation::Block::map_borrowed(
      _handle.memoryEntry, _handle.capacityBytes, *_proof);
  if (!result) {
    _snapshot.kernelResult = result.kernel_result;
    [self fail:failure(3111, [NSString stringWithFormat:@"Donor mapping failed: %s (%d)",
       neostation::donation::stage_name(result.stage), result.kernel_result])];
    return;
  }
  const uint64_t chunkIndex = [_pendingMetadata[@"chunkIndex"] unsignedLongLongValue];
  const uint64_t donorPattern = NeoSwapDonorChunkPattern(_nonce, _snapshot.generation, chunkIndex, NO);
  const uint64_t hostPattern = NeoSwapDonorChunkPattern(_nonce, _snapshot.generation, chunkIndex, YES);
  auto bytes = static_cast<unsigned char*>(_proof->data());
  for (uint64_t offset = 0; offset < _handle.capacityBytes; offset += vm_page_size) {
    uint64_t actual = 0;
    std::memcpy(&actual, bytes + offset, sizeof(actual));
    if (actual != donorPattern) {
      [self fail:failure(3112, @"Donor mapping did not contain the authenticated shared-page pattern")];
      return;
    }
  }
  for (uint64_t offset = 0; offset < _handle.capacityBytes; offset += vm_page_size)
    std::memcpy(bytes + offset, &hostPattern, sizeof(hostPattern));
  if (_snapshot.state == NeoSwapDonorStateLaunching) _snapshot.state = NeoSwapDonorStateVerifying;
  _diagnostics[@"stage"] = @"verifying_shared_pages";
  _snapshot.donorPID = _expectedPID;
  auto reply = _pendingReply;
  _pendingReply = nil;
  reply(YES);
}

- (void)donorUpdate:(NSDictionary*)metadata reply:(void (^)(uint64_t))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    if ((self->_snapshot.state != NeoSwapDonorStateVerifying &&
         self->_snapshot.state != NeoSwapDonorStateActive) ||
        ![self validMetadata:metadata source:source] ||
        self->_expectedPID != source.processIdentifier ||
        ![metadata[@"proofComplete"] isEqual:@YES]) {
      reply(0);
      [self fail:failure(3113, @"Rejected donor accounting/verification update")];
      return;
    }
    for (NSString* key in @[@"residentDelta", @"compressedDelta", @"footprint",
                            @"nonvolatile", @"compressed", @"headroom", @"kernelResult"]) {
      if (!number(metadata, key)) {
        reply(0);
        [self fail:failure(3114, @"Donor accounting update is missing measured kernel fields")];
        return;
      }
    }
    const BOOL newChunk = self->_handle != nil && !self->_pendingReply;
    const uint64_t candidate = self->_snapshot.capacityBytes +
                              (newChunk ? self->_handle.capacityBytes : 0);
    const uint64_t resident = [metadata[@"residentDelta"] unsignedLongLongValue];
    const uint64_t compressed = [metadata[@"compressedDelta"] unsignedLongLongValue];
    const uint64_t chunkCount = [metadata[@"verifiedChunkCount"] unsignedLongLongValue];
    if ([metadata[@"kernelResult"] intValue] != KERN_SUCCESS || resident > candidate ||
        compressed > candidate || resident > candidate - compressed ||
        [metadata[@"capacityBytes"] unsignedLongLongValue] != candidate ||
        chunkCount != self->_handles.count + (newChunk ? 1 : 0) ||
        (newChunk && ([metadata[@"chunkIndex"] unsignedLongLongValue] != self->_handles.count ||
                      [metadata[@"chunkBytes"] unsignedLongLongValue] != self->_handle.capacityBytes)) ||
        (!newChunk && (!self->_handles.count ||
           [metadata[@"chunkIndex"] unsignedLongLongValue] != self->_handles.count - 1 ||
           [metadata[@"chunkBytes"] unsignedLongLongValue] != self->_handles.lastObject.capacityBytes))) {
      reply(0);
      [self fail:failure(3115, @"Donor cumulative accounting/index measurement failed or exceeds its objects")];
      return;
    }
    if (newChunk) {
      const uint64_t accounted = resident + compressed;
      const uint64_t tolerance = MIN(1024ULL * 1024, self->_handle.capacityBytes / 16);
      if (accounted < candidate - tolerance || accounted < self->_beforeChunkAccounted ||
          accounted - self->_beforeChunkAccounted < self->_handle.capacityBytes - tolerance ||
          !number(metadata, @"chunkAccountedDelta") ||
          [metadata[@"chunkAccountedDelta"] unsignedLongLongValue] < self->_handle.capacityBytes - tolerance ||
          [metadata[@"chunkAccountedDelta"] unsignedLongLongValue] > self->_handle.capacityBytes) {
        reply(0);
        [self fail:failure(3118, @"The new chunk did not add independently measured donor ledger pages")];
        return;
      }
      [self->_handles addObject:self->_handle];
      self->_handle = nil;
      self->_pendingMetadata = nil;
      self->_snapshot.capacityBytes = candidate;
      self->_snapshot.verifiedChunkCount = self->_handles.count;
      self->_snapshot.growthState = candidate == self->_requested
          ? NeoSwapDonorGrowthComplete : NeoSwapDonorGrowthIdle;
      self->_snapshot.refusedBytes = 0;
      self->_inFlightMaximum = 0;
      self->_diagnostics[@"growthStage"] = candidate == self->_requested ? @"target_complete" : @"ready";
      self->_diagnostics[@"refusedBytes"] = @0;
      [self->_diagnostics removeObjectForKey:@"pendingChunkIndex"];
      [self->_diagnostics removeObjectForKey:@"pendingChunkBytes"];
      if (self->_proof) {
        const auto released = self->_proof->reset();
        if (!released) {
          reply(0);
          self->_snapshot.kernelResult = released.kernel_result;
          [self fail:failure(3119, @"Verified chunk proof mapping cleanup failed; ownership retained")];
          return;
        }
        self->_proof.reset();
      }
    } else if ([metadata[@"growthRefused"] isEqual:@YES]) {
      if (!number(metadata, @"refusedBytes") ||
          [metadata[@"refusedBytes"] unsignedLongLongValue] != self->_inFlightMaximum ||
          ![metadata[@"growthStage"] isKindOfClass:NSString.class] ||
          self->_snapshot.growthState != NeoSwapDonorGrowthPreparing) {
        reply(0);
        [self fail:failure(3122, @"Rejected unsolicited or malformed donor growth refusal")];
        return;
      }
      self->_snapshot.growthState = NeoSwapDonorGrowthRefused;
      self->_snapshot.refusedBytes = [metadata[@"refusedBytes"] unsignedLongLongValue];
      self->_inFlightMaximum = 0;
      self->_diagnostics[@"growthStage"] = metadata[@"growthStage"];
      self->_diagnostics[@"refusedBytes"] = @(self->_snapshot.refusedBytes);
    }
    self->_snapshot.donatedResidentBytes = resident;
    self->_snapshot.donatedCompressedBytes = compressed;
    self->_snapshot.donorFootprintBytes = [metadata[@"footprint"] unsignedLongLongValue];
    self->_snapshot.donorNonvolatileBytes = [metadata[@"nonvolatile"] unsignedLongLongValue];
    self->_snapshot.donorCompressedBytes = [metadata[@"compressed"] unsignedLongLongValue];
    self->_snapshot.donorHeadroomBytes = [metadata[@"headroom"] unsignedLongLongValue];
    self->_snapshot.kernelResult = [metadata[@"kernelResult"] intValue];
    self->_snapshot.state = NeoSwapDonorStateActive;
    self->_diagnostics[@"stage"] = @"verified";
    self->_diagnostics[@"targetBytes"] = @(self->_requested);
    self->_diagnostics[@"actualCapacityBytes"] = @(candidate);
    self->_diagnostics[@"verifiedChunkCount"] = @(self->_snapshot.verifiedChunkCount);
    self->_diagnostics[@"lastVerifiedChunkIndex"] = metadata[@"chunkIndex"];
    self->_diagnostics[@"lastVerifiedChunkBytes"] = metadata[@"chunkBytes"];
    self->_diagnostics[@"growthState"] = @(self->_snapshot.growthState);
    self->_diagnostics[@"headroomBytes"] = @(self->_snapshot.donorHeadroomBytes);
    self->_diagnostics[@"processHeadroomRequired"] = metadata[@"processHeadroomRequired"] ?: NSNull.null;
    self->_diagnostics[@"simulator"] = metadata[@"simulator"] ?: NSNull.null;
    self->_diagnostics[@"systemHeadroomBytes"] = metadata[@"systemHeadroomBytes"] ?: NSNull.null;
    self->_diagnostics[@"systemPressure"] = metadata[@"systemPressure"] ?: NSNull.null;
    self->_diagnostics[@"measurement"] = @"donor_process_nonvolatile_ledger_delta_bounded_by_verified_chunks";
    self->_diagnostics[@"donorNonvolatileBaseline"] = metadata[@"baselineNonvolatile"] ?: NSNull.null;
    self->_diagnostics[@"donorCompressedBaseline"] = metadata[@"baselineCompressed"] ?: NSNull.null;
    self->_diagnostics[@"lastChunkAccountedDelta"] = metadata[@"chunkAccountedDelta"] ?: NSNull.null;
    if ([metadata[@"effectiveEntitlements"] isKindOfClass:NSDictionary.class])
      self->_diagnostics[@"helperEffectiveEntitlements"] = metadata[@"effectiveEntitlements"];
    self->_lastUpdate = Clock::now();
    [self notify:nil];
    uint64_t budget = 0;
    if (self->_snapshot.state == NeoSwapDonorStateActive && self->_nextMaximum &&
        self->_acknowledgedChunks == self->_handles.count && !self->_handle) {
      budget = self->_nextMaximum;
      self->_inFlightMaximum = budget;
      self->_nextMaximum = 0;
      self->_snapshot.growthState = NeoSwapDonorGrowthPreparing;
      self->_chunkStarted = Clock::now();
    }
    reply(budget);
  });
}

- (void)donorFailed:(NSDictionary*)metadata reply:(void (^)(void))reply {
  NSXPCConnection* source = NSXPCConnection.currentConnection;
  dispatch_async(_queue, ^{
    reply();
    if ([self validMetadata:metadata source:source] &&
        [metadata[@"stage"] isKindOfClass:NSString.class] && number(metadata, @"kernelResult")) {
      self->_snapshot.kernelResult = [metadata[@"kernelResult"] intValue];
      self->_diagnostics[@"stage"] = metadata[@"stage"];
      self->_diagnostics[@"kernelResult"] = metadata[@"kernelResult"];
      self->_diagnostics[@"actualCapacityBytes"] = metadata[@"capacityBytes"];
      self->_diagnostics[@"headroomBytes"] = metadata[@"headroom"] ?: NSNull.null;
      self->_diagnostics[@"headroomAPIAvailable"] = metadata[@"headroomAPIAvailable"] ?: NSNull.null;
      self->_diagnostics[@"processHeadroomRequired"] = metadata[@"processHeadroomRequired"] ?: NSNull.null;
      self->_diagnostics[@"simulator"] = metadata[@"simulator"] ?: NSNull.null;
      if ([metadata[@"effectiveEntitlements"] isKindOfClass:NSDictionary.class])
        self->_diagnostics[@"helperEffectiveEntitlements"] = metadata[@"effectiveEntitlements"];
      [self fail:failure(3116, [NSString stringWithFormat:@"Donor %s failed (%d)",
          [metadata[@"stage"] UTF8String], self->_snapshot.kernelResult])];
    } else [self fail:failure(3117, @"Rejected malformed donor failure report")];
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
  _pendingMetadata = nil;
  if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
  [_connection invalidate];
  _connection = nil;
  [_listener invalidate];
  _listener = nil;
  [self cancelRequest];
  // Pool mappings hold their own send rights and mappings. Tearing down this
  // proof map does not invalidate any caller-owned borrowed allocation.
  if (_proof) {
    const auto released = _proof->reset();
    if (released) {
      _proof.reset();
      _diagnostics[@"cleanupPending"] = @NO;
    } else {
      // Keep retry ownership; the broker destructor also quarantines a failed
      // resource if the enclosing session itself is later destroyed.
      _diagnostics[@"cleanupPending"] = @YES;
      _diagnostics[@"cleanupStage"] = [NSString stringWithUTF8String:
          neostation::donation::stage_name(released.stage)];
      _diagnostics[@"cleanupKernelResult"] = @(released.kernel_result);
    }
  }
  _handle = nil;
  [_handles removeAllObjects];
  _nextMaximum = 0;
  _inFlightMaximum = 0;
  (void)neostation::donation::retry_cleanup();
  neostation::donation::CleanupSnapshot cleanup;
  neostation::donation::cleanup_snapshot(cleanup);
  _diagnostics[@"quarantinedCleanupBlocks"] = @(cleanup.pending_blocks);
  _diagnostics[@"quarantinedCleanupMappings"] = @(cleanup.pending_mappings);
  _diagnostics[@"quarantinedCleanupRights"] = @(cleanup.pending_rights);
  _snapshot.donatedResidentBytes = 0;
  _snapshot.donatedCompressedBytes = 0;
}

- (void)fail:(NSError*)error {
  if (_snapshot.state == NeoSwapDonorStateFailed || _snapshot.state == NeoSwapDonorStateClosed) return;
  _snapshot.state = NeoSwapDonorStateFailed;
  _diagnostics[@"errorDomain"] = error.domain;
  _diagnostics[@"errorCode"] = @(error.code);
  _diagnostics[@"technicalError"] = error.localizedDescription;
  [self tearDown];
  [self notify:error];
}

- (void)close {
  dispatch_async(_queue, ^{
    if (self->_snapshot.state == NeoSwapDonorStateClosed) {
      [self tearDown];
      return;
    }
    self->_snapshot.state = NeoSwapDonorStateClosed;
    self->_diagnostics[@"stage"] = @"closed";
    [self tearDown];
    NSError* cleanup = [self->_diagnostics[@"cleanupPending"] isEqual:@YES]
        ? failure(3119, @"Donor proof mapping cleanup is pending; retry ownership retained") : nil;
    [self notify:cleanup];
    self->_observer = nil;
  });
}

- (NeoSwapDonorSnapshot)snapshot {
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) return _snapshot;
  __block NeoSwapDonorSnapshot result{};
  dispatch_sync(_queue, ^{ result = self->_snapshot; });
  return result;
}

- (NSDictionary*)diagnostics {
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) return [_diagnostics copy];
  __block NSDictionary* result;
  dispatch_sync(_queue, ^{ result = [self->_diagnostics copy]; });
  return result;
}

- (mach_port_t)copyMemoryEntry {
  return [self copyMemoryEntryForChunk:0];
}

- (mach_port_t)copyMemoryEntryForChunk:(uint64_t)index {
  __block mach_port_t result = MACH_PORT_NULL;
  void (^copy)(void) = ^{
    if (self->_snapshot.state == NeoSwapDonorStateActive && index < self->_handles.count) {
      NeoSwapMachHandle* handle = self->_handles[static_cast<NSUInteger>(index)];
      if (mach_port_mod_refs(mach_task_self(), handle.memoryEntry,
                            MACH_PORT_RIGHT_SEND, 1) == KERN_SUCCESS)
        result = handle.memoryEntry;
    }
  };
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) copy();
  else dispatch_sync(_queue, copy);
  return result;
}

- (uint64_t)chunkCapacityBytes:(uint64_t)index {
  __block uint64_t result = 0;
  void (^read)(void) = ^{
    if (self->_snapshot.state == NeoSwapDonorStateActive && index < self->_handles.count)
      result = self->_handles[static_cast<NSUInteger>(index)].capacityBytes;
  };
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) read();
  else dispatch_sync(_queue, read);
  return result;
}

- (BOOL)acknowledgeVerifiedChunk:(uint64_t)index {
  __block BOOL accepted = NO;
  void (^ack)(void) = ^{
    if (self->_snapshot.state == NeoSwapDonorStateActive &&
        index == self->_acknowledgedChunks && index < self->_handles.count) {
      ++self->_acknowledgedChunks;
      accepted = YES;
    }
  };
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) ack();
  else dispatch_sync(_queue, ack);
  return accepted;
}

- (BOOL)requestNextChunkWithMaximumBytes:(uint64_t)bytes {
  __block BOOL accepted = NO;
  void (^request)(void) = ^{
    if (self->_snapshot.state != NeoSwapDonorStateActive || self->_handle || self->_nextMaximum ||
        self->_snapshot.growthState == NeoSwapDonorGrowthPreparing ||
        self->_acknowledgedChunks != self->_handles.count ||
        self->_handles.count >= 64 || bytes < 1024 * 1024 || bytes > 256ULL * 1024 * 1024 ||
        bytes % vm_page_size || self->_snapshot.capacityBytes >= self->_requested ||
        self->_requested - self->_snapshot.capacityBytes < 1024 * 1024) return;
    self->_nextMaximum = MIN(bytes, self->_requested - self->_snapshot.capacityBytes);
    self->_snapshot.growthState = NeoSwapDonorGrowthRequested;
    self->_snapshot.refusedBytes = 0;
    self->_diagnostics[@"growthStage"] = @"requested";
    accepted = YES;
  };
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) request();
  else dispatch_sync(_queue, request);
  return accepted;
}

- (BOOL)setInitialChunkMaximumBytes:(uint64_t)bytes {
  __block BOOL accepted = NO;
  void (^configure)(void) = ^{
    if (self->_snapshot.state == NeoSwapDonorStateIdle && bytes >= 1024 * 1024 &&
        bytes <= 64ULL * 1024 * 1024 && bytes <= self->_requested && bytes % vm_page_size == 0) {
      self->_initialMaximum = bytes;
      self->_diagnostics[@"initialMaximumBytes"] = @(bytes);
      accepted = YES;
    }
  };
  if (dispatch_get_specific(&queueKey) == (__bridge void*)self) configure();
  else dispatch_sync(_queue, configure);
  return accepted;
}

- (void)dealloc {
  if (_timer) dispatch_source_cancel(_timer);
  [_connection invalidate];
  [_listener invalidate];
  [self cancelRequest];
}

#if defined(NEOSWAP_DONATION_PROBE)
- (void)startWithServiceNameForProbe:(NSString*)serviceName {
  dispatch_async(_queue, ^{
    if (self->_snapshot.state != NeoSwapDonorStateIdle) return;
    self->_probe = YES;
    self->_connection = [[NSXPCConnection alloc] initWithServiceName:serviceName];
    self->_connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:
        @protocol(NeoSwapDonorProbeProtocol)];
    [self beginTimer];
    [self configureConnection:self->_connection];
    id<NeoSwapDonorProbeProtocol> proxy = [self->_connection remoteObjectProxyWithErrorHandler:^(NSError* error) {
      dispatch_async(self->_queue, ^{ [self fail:error]; });
    }];
    [proxy beginProbe:[self requestMetadata]];
  });
}
#endif
@end
