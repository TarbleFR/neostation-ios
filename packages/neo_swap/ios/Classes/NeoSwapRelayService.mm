#import "NeoSwapRelayService.h"
#import "NeoSwapRelay.h"
#import "Relay/NeoSwapPageRelay.h"
#include "Relay/Backend.h"
#include "NeoSwapExperiment.h"
#include "NeoSwapHost.h"
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <algorithm>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
constexpr uint64_t kCapacity = 8 * 1024 * MiB;
constexpr uint64_t kSegment = 512 * MiB;
constexpr uint32_t kRPCS3 = 0;
constexpr NSTimeInterval kNormalRetryDelaySeconds = 30.0;
constexpr NSTimeInterval kFastFootprintRetryDelaySeconds = 0.15;
constexpr NSUInteger kMaxFastFootprintRetries = 1;
bool footprint(uint64_t& bytes) {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS ||
        count < TASK_VM_INFO_REV1_COUNT)
        return false;
    bytes = info.phys_footprint;
    return true;
}
uint64_t pattern(uint64_t i) {
    uint64_t value = i + 0x9e3779b97f4a7c15ULL;
    value = (value ^ (value >> 30)) * 0xbf58476d1ce4e5b9ULL;
    value = (value ^ (value >> 27)) * 0x94d049bb133111ebULL;
    return value ^ (value >> 31);
}
// Small, explicitly labelled capability check. The returned capacity is never
// treated as touched/resident memory or as a real game's allocation count.
NSDictionary* capabilityCheck() {
    const NeoSwapRelayAPI* api = NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI);
    uint64_t before = 0, after = 0, token = 0;
    void* first = nullptr;
    void* second = nullptr;
    constexpr uint64_t bytes = 16 * MiB;
    int result = api && footprint(before) ? NEOSWAP_RELAY_OK : NEOSWAP_RELAY_DISABLED;
    if (result == 0) result = api->create(kRPCS3, bytes, &token);
    if (result == 0) result = api->map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &first);
    if (result == 0) result = api->map(token, nullptr, NEOSWAP_RELAY_READ, &second);
    bool coherent = result == 0;
    if (coherent) {
        auto* writer = static_cast<volatile uint64_t*>(first);
        auto* reader = static_cast<const volatile uint64_t*>(second);
        for (uint64_t i = 0; i < bytes / sizeof(uint64_t); ++i) writer[i] = pattern(i);
        for (uint64_t i = 0; i < bytes / sizeof(uint64_t); ++i)
            if (reader[i] != pattern(i)) { coherent = false; break; }
        if (!coherent) result = NEOSWAP_RELAY_MAPPING;
        if (!footprint(after)) result = NEOSWAP_RELAY_MAPPING;
        // A creator-exit callback proves lifecycle, not accounting. Refuse the
        // new backend on this device if almost all test pages bill to the host.
        if (after > before && after - before >= 4 * MiB) result = NEOSWAP_RELAY_LIMIT;
    }
    int cleanup = 0;
    if (second) cleanup = api->unmap(token, second);
    if (first) { const int code = api->unmap(token, first); if (code) cleanup = code; }
    if (token) { const int code = api->retire(token); if (code) cleanup = code; }
    if (cleanup) result = cleanup;
    return @{@"kind":@"post_creator_exit_cpu_capability_check",
             @"requestedBytes":@(bytes), @"aliasDataVerified":@(coherent),
             @"hostFootprintBeforeBytes":@(before), @"hostFootprintAfterBytes":@(after),
             @"hostFootprintDeltaBytes":@(after > before ? after - before : 0),
             @"cleanupResult":@(cleanup), @"result":@(result),
             @"gameplayValidated":@NO, @"residentBytes":NSNull.null};
}
}

@interface NeoSwapRelayManager : NSObject
- (void)start;
- (void)maintain;
- (int)waitReady:(uint32_t)timeout;
- (NSDictionary*)diagnostics;
- (void)consumeHandles:(NSArray<NeoSwapPageRelayHandle*>*)handles pid:(int32_t)pid
            generation:(uint64_t)generation expectedGeneration:(uint64_t)expected error:(NSError*)error;
- (void)finishGeneration:(uint64_t)generation details:(NSDictionary*)details ready:(BOOL)ready;
@end

@implementation NeoSwapRelayManager {
    NSLock* _lock;
    dispatch_queue_t _queue;
    dispatch_group_t _pending;
    dispatch_source_t _pressure;
    NeoSwapPageRelaySession* _session;
    NSDictionary* _details;
    BOOL _running;
    BOOL _ready;
    BOOL _sessionObserved;
    BOOL _memoryPressureRaised;
    uint64_t _generation;
    NSTimeInterval _retryAfter;
    NSUInteger _fastFootprintRetryCount;
    BOOL _fastFootprintRetryPending;
}
- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _queue = dispatch_queue_create("neostation.neoswap.guest-relay", DISPATCH_QUEUE_SERIAL);
        _details = @{@"state":@"idle", @"targetCapacityBytes":@(kCapacity)};
        _pressure = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, _queue);
        __weak NeoSwapRelayManager* weakSelf = self;
        dispatch_source_set_event_handler(_pressure, ^{
            NeoSwapRelayManager* self = weakSelf;
            if (!self) return;
            const bool raised = (dispatch_source_get_data(self->_pressure) &
                (DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL)) != 0;
            [self->_lock lock];
            self->_memoryPressureRaised = raised;
            [self->_lock unlock];
            neostation::relay::set_pressure(raised);
            if (raised) {
                NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_RELAY_ABI;
                NeoSwap_GetRelayAPI(1)->snapshot(&stats);
                if (!stats.object_count) {
                    [self->_lock lock];
                    const BOOL idle = !self->_running;
                    if (idle) self->_ready = NO;
                    [self->_lock unlock];
                    if (idle) {
                        (void)neostation::relay::shutdown();
                        neostation::relay::set_pressure(true);
                    }
                }
            } else [self start];
        });
        dispatch_resume(_pressure);
    }
    return self;
}
- (void)start {
    if (!NeoSwapExperimentProfile().relay()) return;
    [_lock lock];
    if (_ready || _running || _memoryPressureRaised || NSDate.date.timeIntervalSince1970 < _retryAfter) {
        [_lock unlock]; return;
    }
    _running = YES;
    _sessionObserved = NO;
    _fastFootprintRetryPending = NO;
    _pending = dispatch_group_create();
    dispatch_group_enter(_pending);
    const uint64_t generation = ++_generation;
    _details = @{@"state":@"preparing", @"generation":@(generation),
                 @"targetCapacityBytes":@(kCapacity)};
    [_lock unlock];
    dispatch_async(_queue, ^{
        if (self->_memoryPressureRaised) {
            [self finishGeneration:generation details:@{@"state":@"memory_pressure",
                @"result":@(NEOSWAP_RELAY_PRESSURE)} ready:NO];
            return;
        }
        // A prior failed OS cleanup stays owned by the backend and is retried
        // before a new helper can publish another set of named objects.
        int setup = neostation::relay::shutdown();
        if (setup == 0) {
            neostation::relay::set_pressure(self->_memoryPressureRaised);
            setup = neostation::relay::configure(1u << kRPCS3, kCapacity);
        }
        if (setup != 0) {
            [self finishGeneration:generation details:@{@"state":@"backend_refused", @"result":@(setup)} ready:NO];
            return;
        }
        NSString* identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".NeoSwapPageRelay"];
        __weak NeoSwapRelayManager* weakSelf = self;
        self->_session = [[NeoSwapPageRelaySession alloc] initWithHelperIdentifier:identifier
            requestedBytes:kCapacity generation:generation timeout:10
            completion:^(NSArray<NeoSwapPageRelayHandle*>* handles, int32_t pid,
                         uint64_t returnedGeneration, NSError* error) {
                NeoSwapRelayManager* owner = weakSelf;
                if (!owner) return;
                dispatch_async(owner->_queue, ^{
                    [owner consumeHandles:handles pid:pid generation:returnedGeneration
                         expectedGeneration:generation error:error];
                });
            }];
        [self->_session start];
    });
}
- (void)consumeHandles:(NSArray<NeoSwapPageRelayHandle*>*)handles pid:(int32_t)pid
            generation:(uint64_t)generation expectedGeneration:(uint64_t)expected error:(NSError*)error {
    [_lock lock];
    const BOOL active = _running && _generation == expected;
    const BOOL pressureRaised = _memoryPressureRaised;
    [_lock unlock];
    if (!active) return;
    NSMutableDictionary* details = [[_session diagnostics] mutableCopy] ?: [NSMutableDictionary new];
    int result = error || generation != expected || pid <= 0 || handles.count != kCapacity / kSegment
        ? NEOSWAP_RELAY_INVALID : NEOSWAP_RELAY_OK;
    if (pressureRaised) result = NEOSWAP_RELAY_PRESSURE;
    NSDictionary* measured = nil;
    for (NeoSwapPageRelayHandle* handle in handles) {
        if (result != 0) break;
        if (handle.capacityBytes != kSegment) { result = NEOSWAP_RELAY_INVALID; break; }
        result = neostation::relay::adopt(handle.memoryEntry, handle.capacityBytes, pid, generation);
    }
    if (result == 0) {
        measured = capabilityCheck();
        details[@"capabilityCheck"] = measured;
        result = [measured[@"result"] intValue];
    }
    if (result == 0) result = neostation::relay::configure(1u << kRPCS3, kCapacity);
    if (result != 0) {
        (void)neostation::relay::configure(0, kCapacity);
        const int cleanup = neostation::relay::shutdown();
        details[@"failedPreparationCleanupResult"] = @(cleanup);
        [_lock lock];
        const BOOL pressureRaisedAfterCleanup = _memoryPressureRaised;
        [_lock unlock];
        const BOOL retryableFootprintLimit = result == NEOSWAP_RELAY_LIMIT && measured &&
            [measured[@"aliasDataVerified"] isEqual:@YES] &&
            [measured[@"cleanupResult"] intValue] == NEOSWAP_RELAY_OK &&
            cleanup == NEOSWAP_RELAY_OK && !pressureRaisedAfterCleanup;
        details[@"retryableFootprintLimit"] = @(retryableFootprintLimit);
        if (cleanup || pressureRaisedAfterCleanup) neostation::relay::set_pressure(true);
    }
    details[@"state"] = result == 0 ? @"ready" : @"unavailable";
    details[@"result"] = @(result);
    details[@"creatorPID"] = @(pid);
    details[@"creatorGeneration"] = @(generation);
    details[@"residentBytes"] = NSNull.null;
    details[@"compressedBytes"] = NSNull.null;
    if (error) details[@"technicalError"] = error.localizedDescription ?: @"relay preparation failed";
    [self finishGeneration:expected details:details ready:result == 0];
}
- (void)finishGeneration:(uint64_t)generation details:(NSDictionary*)details ready:(BOOL)ready {
    [_lock lock];
    if (!_running || _generation != generation) { [_lock unlock]; return; }
    _details = [details copy];
    _ready = ready;
    _running = NO;
    const NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    const BOOL fastRetryEligible = !ready && [details[@"retryableFootprintLimit"] isEqual:@YES] &&
        _fastFootprintRetryCount < kMaxFastFootprintRetries;
    if (ready) {
        _fastFootprintRetryCount = 0;
        _fastFootprintRetryPending = NO;
        _retryAfter = 0;
    } else if (fastRetryEligible) {
        ++_fastFootprintRetryCount;
        _fastFootprintRetryPending = YES;
        _retryAfter = now + kFastFootprintRetryDelaySeconds;
    } else {
        _fastFootprintRetryPending = NO;
        _retryAfter = now + kNormalRetryDelaySeconds;
    }
    dispatch_group_t completed = _pending;
    [_lock unlock];
    _session = nil;
    dispatch_group_leave(completed);
}
- (int)waitReady:(uint32_t)timeout {
    if (!NeoSwapExperimentProfile().relay()) return NEOSWAP_RELAY_DISABLED;
    [self start];
    const uint32_t boundedTimeout = std::min(timeout, 10000u);
    const NSTimeInterval deadline = NSDate.date.timeIntervalSince1970 +
        (static_cast<NSTimeInterval>(boundedTimeout) / 1000.0);
    for (;;) {
        [_lock lock];
        const BOOL ready = _ready;
        const BOOL running = _running;
        const BOOL fastRetryPending = _fastFootprintRetryPending;
        const NSTimeInterval retryAfter = _retryAfter;
        dispatch_group_t pending = _pending;
        [_lock unlock];
        if (ready) return NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI)->enabled(kRPCS3)
            ? NEOSWAP_RELAY_OK : NEOSWAP_RELAY_DISABLED;
        if (NSThread.isMainThread || !boundedTimeout) return NEOSWAP_RELAY_DISABLED;
        const NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        if (now >= deadline) return NEOSWAP_RELAY_DISABLED;
        if (running && pending) {
            const NSTimeInterval remaining = deadline - now;
            dispatch_group_wait(pending, dispatch_time(DISPATCH_TIME_NOW,
                static_cast<int64_t>(remaining * NSEC_PER_SEC)));
            continue;
        }
        if (!fastRetryPending || retryAfter > deadline) return NEOSWAP_RELAY_DISABLED;
        if (retryAfter > now) {
            [NSThread sleepForTimeInterval:std::min(retryAfter - now, deadline - now)];
            continue;
        }
        [self start];
    }
}
- (void)maintain {
    if (!NeoSwapExperimentProfile().relay()) return;
    dispatch_async(_queue, ^{
        (void)neostation::relay::collect();
        // Preserve preparation until RPCS3 can map Core data. After a game,
        // idle maintenance only retires RPCS3 pages, never starts a helper.
        const BOOL active = NeoSwap_OwnerSessionActive(kRPCS3);
        [self->_lock lock];
        if (active) self->_sessionObserved = YES;
        const BOOL observed = self->_sessionObserved;
        [self->_lock unlock];
        if (!observed) return;
        if (self->_memoryPressureRaised || !active) {
            NeoSwapRelayStats stats{};
            stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_RELAY_ABI;
            NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI)->snapshot(&stats);
            [self->_lock lock];
            const BOOL idle = !self->_running && !stats.object_count;
            if (idle) self->_ready = NO;
            [self->_lock unlock];
            if (idle) (void)neostation::relay::shutdown();
            neostation::relay::set_pressure(self->_memoryPressureRaised);
        } else [self start];
    });
}
- (NSDictionary*)diagnostics {
    [_lock lock];
    NSMutableDictionary* result = [_details mutableCopy];
    result[@"ready"] = @(_ready);
    result[@"experimentMode"] = [NSString stringWithUTF8String:NeoSwapExperimentProfile().name()];
    result[@"preparationRunning"] = @(_running);
    result[@"fastFootprintRetryCount"] = @(_fastFootprintRetryCount);
    result[@"fastFootprintRetryPending"] = @(_fastFootprintRetryPending);
    [_lock unlock];
    NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_RELAY_ABI;
    NeoSwap_GetRelayAPI(1)->snapshot(&stats);
    result[@"abi"] = @1;
    result[@"capacityBytes"] = @(stats.capacity_bytes);
    result[@"retainedCapacityBytes"] = @(stats.retained_capacity_bytes);
    result[@"liveBackingBytes"] = @(stats.live_bytes);
    result[@"peakLiveBackingBytes"] = @(stats.peak_live_bytes);
    result[@"objectCount"] = @(stats.object_count);
    result[@"aliasCount"] = @(stats.alias_count);
    result[@"mappedAliasBytes"] = @(stats.mapped_alias_bytes);
    result[@"pendingCleanupEntries"] = @(stats.pending_cleanup_entries);
    result[@"retiringObjectCount"] = @(stats.retiring_object_count);
    result[@"quarantinedFixedAliasCount"] = @(stats.quarantined_fixed_alias_count);
    result[@"pressureRaised"] = @(stats.pressure_raised);
    result[@"lastResult"] = @(stats.last_result);
    result[@"lastOSError"] = @(stats.last_os_error);
    result[@"rejectionCount"] = @(stats.rejection_count);
    result[@"osErrorCount"] = @(stats.os_error_count);
    const auto pressure = neostation::relay::backend().pressure_diagnostics();
    result[@"pressureTransitions"] = @(pressure.transitions);
    result[@"existingAliasMapsUnderPressure"] = @(pressure.existing_alias_maps);
    result[@"createPressureRefusals"] = @(pressure.create_refusals);
    result[@"firstMapPressureRefusals"] = @(pressure.first_map_refusals);
    result[@"mapFailureCount"] = @(pressure.map_failures);
    result[@"lastMapFailureResult"] = @(pressure.last_map_result);
    result[@"lastMapFailureOSError"] = @(pressure.last_map_os_error);
    if (stats.quarantined_fixed_alias_count) {
        result[@"ready"] = @NO;
        result[@"state"] = @"fixed_alias_quarantined";
    } else if (stats.pressure_raised) {
        result[@"ready"] = @NO;
        result[@"state"] = @"memory_pressure";
    }
    return result;
}
@end

static NeoSwapRelayManager* manager() {
    static NeoSwapRelayManager* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [NeoSwapRelayManager new]; });
    return instance;
}
extern "C" void NeoSwapRelay_Start(void) { [manager() start]; }
extern "C" void NeoSwapRelay_Maintain(void) { [manager() maintain]; }
extern "C" int NeoSwapRelay_WaitReady(uint32_t timeout_ms) { return [manager() waitReady:timeout_ms]; }
NSDictionary* NeoSwapRelay_Diagnostics(void) { return [manager() diagnostics]; }
