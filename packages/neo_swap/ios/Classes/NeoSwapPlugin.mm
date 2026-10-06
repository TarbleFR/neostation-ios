#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
#include "NeoSwapHost.h"
#include "NeoSwapCapacityProbe.h"
#include "NeoSwapMemorySamples.h"
#include "NeoSwapExperiment.h"
#include "NeoSwapBudget.h"
#import <UIKit/UIKit.h>
#if defined(NEOSWAP_SHADER_STORAGE)
#import "NeoSwapStorageService.h"
#endif
#if defined(NEOSWAP_RELAY)
#import "NeoSwapRelayService.h"
#import "NeoSwapRelay.h"
#include "Relay/Backend.h"
#endif
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <algorithm>
#include <dlfcn.h>
#if defined(NEOSWAP_DONATION)
#import "Donation/NeoSwapDonorIPC.h"
#include "Donation/Pool.h"
#endif

static NSString* const kDiagnostic = @"NeoSwap-v1.jsonl";
static const uint64_t kMiB = 1024 * 1024;
static const uint64_t kGiB = 1024 * kMiB;
// Build385 adaptive policy: 5 GiB is a hard ceiling, not a startup target.
// Start two verified 256 MiB chunks for real boot buffers, then retain only
// 128 MiB reserve above active donor loans (not file-backed buffers). Growth remains
// fail-closed under kernel/system pressure and prepared pages are retained
// only for the lifetime of the active RPCS3 session.
static const uint64_t kDonationHardLimitBytes = 5 * kGiB;
static const uint64_t kDonationWarmFloorBytes = 512 * kMiB;
static const uint64_t kDonationReserveBytes = 128 * kMiB;
static const uint64_t kDonationGrowthQuantumBytes = 128 * kMiB;
static const uint64_t kDonationInitialChunkBytes = 256 * kMiB;
static const uint64_t kDonationPrimaryChunkBytes = 256 * kMiB;
static const uint64_t kDonationFallbackChunkBytes = 128 * kMiB;
static const NSUInteger kDonationConcurrentGrowths = 2;
static const NSUInteger kDonationWarmDonorCount = 2;
#if defined(NEOSWAP_DONATION)
static_assert(kDonationPrimaryChunkBytes == neostation::donation::max_chunk_bytes);
static_assert(kDonationInitialChunkBytes == neostation::donation::max_chunk_bytes);
#endif

@interface NeoSwapPlugin () {
    neostation::diagnostics::MemorySamples _memorySamples;
    // Global budget controller: last decision and its sampled inputs, applied
    // on every diagnostics tick while an RPCS3 session is active.
    neostation::budget::Inputs _budgetInputs;
    neostation::budget::Decision _budgetDecision;
    uint64_t _budgetDecisionCount;
    uint64_t _budgetStateChanges;
    uint64_t _budgetLastChangeMs;
}
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, strong) dispatch_source_t cpuBufferPressureSource;
@property(nonatomic, assign) BOOL cpuBufferPressureRaised;
@property(nonatomic, copy) NSString* directory;
@property(nonatomic, copy) NSString* diagnosticPath;
@property(nonatomic, copy) NSString* operationPath;
@property(nonatomic, assign) uint64_t lastOperationDrops;
@property(nonatomic, assign) uint64_t iosWarningCount;
@property(nonatomic, assign) NSInteger capacityMiB;
@property(nonatomic, assign) int configResult;
@property(nonatomic, assign) uint64_t lastAllocationCount;
#if defined(NEOSWAP_RELAY)
@property(nonatomic, assign) uint64_t lastRelayLiveBytes;
@property(nonatomic, copy) NSString* lastRelayState;
#endif
@property(nonatomic, assign) int diagnosticErrno;
@property(nonatomic, strong) NSDictionary* diagnosticError;
@property(nonatomic, strong) NSDictionary* lastCapacityProbe;
#if defined(NEOSWAP_DONATION)
@property(nonatomic, strong) NSMutableArray* donorSessions;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* donorAdoptedChunks;
@property(nonatomic, strong) NSMutableArray<NSDate*>* donorRetryAfter;
@property(nonatomic, strong) NSMutableDictionary* donorErrors;
@property(nonatomic, strong) NSMutableDictionary* donorLoggedStates;
@property(nonatomic, strong) NSDictionary* donorGrowthRefusal;
@property(nonatomic, assign) uint64_t donorEpoch;
@property(nonatomic, strong) NSMutableIndexSet* donorPendingIndexes;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* donorPendingMaximums;
@property(nonatomic, strong) NSDate* donorFallbackUntil;
@property(nonatomic, assign) NSUInteger donorLaunchIndex;
@property(nonatomic, assign) NSUInteger donorCursor;
@property(nonatomic, assign) NeoSwapDonationDemand donorDemand;
@property(nonatomic, assign) uint64_t donorGenerationCounter;
#endif
- (void)applyBudget;
- (uint64_t)donorFloorBytes;
- (uint64_t)donorReserveBytes;
@end

static NSDictionary* NeoSwapEffectivePermissions() {
    // Inspect runtime signature values; an entitlement in a requested plist is
    // not reported as granted. Missing Security SPI remains explicitly unknown.
    using Create = CFTypeRef (*)(CFAllocatorRef);
    using Copy = CFTypeRef (*)(CFTypeRef, CFStringRef, CFErrorRef*);
    auto create = reinterpret_cast<Create>(dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf"));
    auto copy = reinterpret_cast<Copy>(dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement"));
    NSArray* keys = @[@"get-task-allow", @"com.apple.developer.kernel.extended-virtual-addressing",
                      @"com.apple.developer.kernel.increased-memory-limit",
                      @"com.apple.developer.kernel.increased-debugging-memory-limit"];
    NSMutableDictionary* result = [NSMutableDictionary new];
    CFTypeRef task = create ? create(kCFAllocatorDefault) : nullptr;
    for (NSString* key in keys) {
        CFErrorRef error = nullptr;
        CFTypeRef value = task && copy ? copy(task, (__bridge CFStringRef)key, &error) : nullptr;
        if (value) {
            result[key] = CFGetTypeID(value) == CFBooleanGetTypeID()
                ? @((BOOL)CFBooleanGetValue((CFBooleanRef)value)) : NSNull.null;
            CFRelease(value);
        } else result[key] = task && copy && !error ? @NO : NSNull.null;
        if (error) CFRelease(error);
    }
    if (task) CFRelease(task);
    return result;
}

@implementation NeoSwapPlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    // One shared broker and one logger even if Flutter creates another engine.
    static NeoSwapPlugin* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[NeoSwapPlugin alloc] init]; });
    FlutterMethodChannel* channel = [FlutterMethodChannel methodChannelWithName:@"neostation/neo_swap"
        binaryMessenger:registrar.messenger];
    [registrar addMethodCallDelegate:instance channel:channel];
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    self.queue = dispatch_queue_create("neostation.neoswap.diagnostics", DISPATCH_QUEUE_SERIAL);
    NSArray<NSString*>* caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    self.directory = [caches.firstObject stringByAppendingPathComponent:@"NeoSwap-v1"];
    NSArray<NSString*>* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString* diagnosticDir = [docs.firstObject stringByAppendingPathComponent:@"Diagnostics"];
    self.diagnosticPath = [diagnosticDir stringByAppendingPathComponent:kDiagnostic];
    self.operationPath = [diagnosticDir stringByAppendingPathComponent:@"NeoSwap-operations.jsonl"];
    // Runtime policy, not an optional user feature. Old Off/budget preferences
    // cannot disable the integrated service after an update or relaunch.
    self.capacityMiB = NeoSwapExperimentProfile().donors() ? 8192 : 0;
    // Relay preparation begins only at RPCS3's explicit WaitReady call.
    dispatch_async(self.queue, ^{
        NSError* error = nil;
        BOOL created = self.directory.length && [[NSFileManager defaultManager]
            createDirectoryAtPath:self.directory withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0700,
                         NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error];
        if (created) {
            [[NSFileManager defaultManager] setAttributes:@{
                NSFilePosixPermissions:@0700,
                NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication}
                ofItemAtPath:self.directory error:&error];
            created = error == nil;
        }
        [[NSFileManager defaultManager] createDirectoryAtPath:diagnosticDir
            withIntermediateDirectories:YES attributes:nil error:nil];
        // The valid donor policy is installed even if the file-cache directory
        // cannot be created. A genuine donor does not require an 8 GiB arena.
        self.configResult = [self configure:self.capacityMiB];
        if (!created && self.configResult == NEOSWAP_OK) self.configResult = NEOSWAP_STORAGE;
        [self appendRecord:[self snapshot:@"process_start"]];
    });
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    // Reuse the existing maintenance queue/timer, never a per-frame poller.
    // Active RPCS3 samples are ~1 s, idle allocator samples remain ~2 s.
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC/4),
        NSEC_PER_SEC/4, NSEC_PER_SEC/20);
    __weak NeoSwapPlugin* weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
        object:nil queue:nil usingBlock:^(__unused NSNotification* notification) {
        NeoSwapPlugin* owner = weakSelf;
        if (!owner || !NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return;
        dispatch_async(owner.queue, ^{
            ++owner.iosWarningCount;
            [owner appendRecord:[owner snapshot:@"ios_memory_warning"]];
        });
    }];
    self.cpuBufferPressureSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
        self.queue);
    dispatch_source_set_event_handler(self.cpuBufferPressureSource, ^{
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        const unsigned long level = dispatch_source_get_data(strongSelf.cpuBufferPressureSource);
        if (NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3))
            strongSelf->_memorySamples.pressure_event(level);
        strongSelf.cpuBufferPressureRaised = (level &
            (DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL)) != 0;
#if defined(NEOSWAP_DONATION)
        if (strongSelf.cpuBufferPressureRaised) NeoSwap_SetCPUBufferPressure(1);
#endif
    });
    dispatch_resume(self.cpuBufferPressureSource);
    dispatch_source_set_event_handler(self.timer, ^{
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        @autoreleasepool {
            [strongSelf applyBudget];
#if defined(NEOSWAP_DONATION)
            (void)neostation::donation::retry_cleanup();
            if (NeoSwapExperimentProfile().donors() && NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) {
                if (!strongSelf.donorSessions) [strongSelf startDonors];
                [strongSelf advanceDonors];
            } else {
                [strongSelf retireDonorsIfIdle];
            }
#endif
#if defined(NEOSWAP_RELAY)
            if (NeoSwapExperimentProfile().relay()) NeoSwapRelay_Maintain();
#endif
#if defined(NEOSWAP_SHADER_STORAGE)
            NSDictionary* operations = NeoSwapStorage_DrainOperations();
            const uint64_t drops = [operations[@"droppedEventsCumulative"] unsignedLongLongValue];
            if ([operations[@"events"] count] || drops != strongSelf.lastOperationDrops) {
                [strongSelf appendRecord:@{@"schema":@1, @"event":@"source_operations",
                    @"timestamp":@(NSDate.date.timeIntervalSince1970), @"pid":@(getpid()),
                    @"mode":[NSString stringWithUTF8String:NeoSwapExperimentProfile().name()],
                    @"batch":operations} toPath:strongSelf.operationPath];
                strongSelf.lastOperationDrops = drops;
            }
#endif
            const bool rpcs3Active = NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3);
            // Keep the final RPCS3 sample, then stop sampling unrelated cores.
            if (!rpcs3Active && !strongSelf->_memorySamples.active()) return;
            const auto event = strongSelf->_memorySamples.poll(
                static_cast<uint64_t>(NSProcessInfo.processInfo.systemUptime * 1000), rpcs3Active);
            using neostation::diagnostics::MemoryEvent;
            if (event == MemoryEvent::none) return;
            NSString* name = event == MemoryEvent::session_start ? @"rpcs3_memory_session_start" :
                event == MemoryEvent::session_end ? @"rpcs3_memory_session_end" :
                event == MemoryEvent::pressure ? @"memory_pressure" : @"sample";
            NSDictionary* row = [strongSelf snapshot:name];
            uint64_t count = [row[@"allocationCount"] unsignedLongLongValue];
            BOOL record = strongSelf->_memorySamples.active() || event != MemoryEvent::sample ||
                [row[@"liveBytes"] unsignedLongLongValue] || count != strongSelf.lastAllocationCount;
#if defined(NEOSWAP_RELAY)
            const uint64_t relayLive = [row[@"guestRelay"][@"liveBackingBytes"] unsignedLongLongValue];
            NSString* relayState = row[@"guestRelay"][@"state"] ?: @"unknown";
            const BOOL relayChanged = relayLive != strongSelf.lastRelayLiveBytes ||
                ![relayState isEqualToString:strongSelf.lastRelayState];
            strongSelf.lastRelayLiveBytes = relayLive;
            strongSelf.lastRelayState = relayState;
            record = record || relayLive || relayChanged;
#endif
            // Record the whole RPCS3 session even when no allocator loan is
            // live. Idle availability alone still creates no periodic writes.
            if (record)
                [strongSelf appendRecord:row];
            strongSelf.lastAllocationCount = count;
        }
    });
    dispatch_resume(self.timer);
    return self;
}
#if defined(NEOSWAP_DONATION)
- (void)startDonors {
    if (!NeoSwapExperimentProfile().donors() || self.donorSessions || !NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return;
    if (NeoSwapExperimentProfile().configured) {
        NeoSwapCPUBufferStats cpu{}; NeoSwapHostStats host{};
        if (NeoSwap_CPUBufferSnapshot(&cpu) != NEOSWAP_OK || NeoSwap_HostSnapshot(&host) != NEOSWAP_OK) return;
        // Warm only a consumer that can use loans. Other games create no
        // donor process until a real allocation miss has queued a demand.
        if (!cpu.enabled && !host.donor_pending_demand_bytes && !host.donor_inflight_demand_bytes) return;
    }
    if (self.donorEpoch >= UINT64_MAX / 16) {
        self.donorGrowthRefusal = @{@"stage":@"donor_epoch_exhausted"};
        return;
    }
    ++self.donorEpoch;
    self.donorGenerationCounter = self.donorEpoch * 16;
    self.donorPendingIndexes = [NSMutableIndexSet indexSet];
    self.donorPendingMaximums = [NSMutableArray new];
    self.donorFallbackUntil = NSDate.distantPast;
    self.donorSessions = [NSMutableArray new];
    self.donorAdoptedChunks = [NSMutableArray new];
    self.donorRetryAfter = [NSMutableArray new];
    self.donorErrors = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < 8; ++index) {
        [self.donorSessions addObject:NSNull.null];
        [self.donorAdoptedChunks addObject:@0];
        [self.donorRetryAfter addObject:NSDate.distantPast];
        [self.donorPendingMaximums addObject:@0];
    }
    auto begun = neostation::donation::pool_campaign_begin(self.donorEpoch, kDonationHardLimitBytes);
    if (!begun) {
        self.donorGrowthRefusal = @{@"stage":[NSString stringWithUTF8String:
            neostation::donation::stage_name(begun.stage)], @"kernelResult":@(begun.kernel_result)};
        return;
    }
    [self advanceDonors];
}
- (uint64_t)nextDonationBudget {
    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    if (pool.generation != self.donorEpoch || pool.retained_bytes >= pool.target_bytes) return 0;
    // The global budget controller refuses donor growth without measured room
    // or while the system is shrinking; explicit demands wait with everyone else.
    if (!_budgetDecision.donor_growth_admitted) {
        self.donorGrowthRefusal = @{@"stage":@"global_budget_refused_growth",
            @"budgetState":[NSString stringWithUTF8String:neostation::budget::state_name(_budgetDecision.state)],
            @"reason":[NSString stringWithUTF8String:_budgetDecision.reason],
            @"kernelResult":@(KERN_RESOURCE_SHORTAGE)};
        return 0;
    }
    neostation::donation::SystemHeadroom system{};
    const auto sampled = neostation::donation::system_headroom(system);
    // phys_footprint includes uncompressed-page equivalents of compressed
    // memory. It is a diagnostic ledger, not free physical RAM to subtract.
    uint64_t available = sampled ? system.usable_bytes : 0;
    // Reserve outstanding requests too: their pages may not yet appear in
    // the kernel sample. Never grant the same headroom to concurrent helpers.
    available = neostation::donation::pending_headroom_budget(available,
        pool.target_bytes - pool.retained_bytes, [self pendingDonationBytes], vm_page_size);
    if (available < kMiB) {
        self.donorGrowthRefusal = @{@"stage":sampled ? @"insufficient_system_headroom" :
            [NSString stringWithUTF8String:neostation::donation::stage_name(sampled.stage)],
            @"kernelResult":@(!sampled ? sampled.kernel_result : KERN_RESOURCE_SHORTAGE),
            @"remainingTargetBytes":@(pool.target_bytes - pool.prepared_bytes),
            @"freeBytes":@(system.free_bytes), @"purgeableBytes":@(system.purgeable_bytes),
            @"systemUsableBytes":@(system.usable_bytes),
            @"pressure":@(static_cast<uint32_t>(system.pressure))};
        return 0;
    }
    self.donorGrowthRefusal = nil;
    return available;
}
- (void)launchDonor:(NSUInteger)index budget:(uint64_t)budget {
    if (self.donorGenerationCounter == UINT64_MAX) {
        self.donorGrowthRefusal = @{@"stage":@"donor_generation_exhausted"};
        return;
    }
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleID.length) return;
    // Separate outstanding requests ask Foundation for distinct instances
    // of the same signed extension. The pool refuses a reused donor PID.
    NSString* identifier = [bundleID stringByAppendingString:@".neoswapdonor"];
    __weak NeoSwapPlugin* weakSelf = self;
    NeoSwapDonorSession* session = [[NeoSwapDonorSession alloc] initWithHelperIdentifier:identifier
        requestedBytes:kDonationHardLimitBytes generation:++self.donorGenerationCounter
        timeout:60 observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot ignored, NSError* failure) {
        (void)ignored;
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{ [strongSelf donorChanged:source index:index error:failure]; });
    }];
    const uint64_t initialMaximum = NeoSwapExperimentProfile().configured
        ? (self.donorDemand.bytes ?: 16*kMiB) : kDonationInitialChunkBytes;
    const uint64_t first = MIN(budget, initialMaximum);
    if (![session setInitialChunkMaximumBytes:first]) {
        self.donorErrors[[NSString stringWithFormat:@"%lu", (unsigned long)index]] =
            @{@"stage":@"initial_chunk_budget", @"bytes":@(first)};
        return;
    }
    self.donorSessions[index] = session;
    self.donorAdoptedChunks[index] = @0;
    self.donorPendingMaximums[index] = @(first);
    [self.donorPendingIndexes addIndex:index];
    [session start];
}
- (void)clearPendingDonor:(NSUInteger)index {
    [self.donorPendingIndexes removeIndex:index];
    if (index < self.donorPendingMaximums.count) self.donorPendingMaximums[index] = @0;
}
- (uint64_t)pendingDonationBytes {
    __block uint64_t total = 0;
    [self.donorPendingIndexes enumerateIndexesUsingBlock:^(NSUInteger index, BOOL* stop) {
        (void)stop;
        if (index < self.donorPendingMaximums.count)
            total += self.donorPendingMaximums[index].unsignedLongLongValue;
    }];
    return total;
}
- (uint64_t)adaptiveDonationTarget {
    if (!NeoSwapExperimentProfile().donors() || !NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return 0;
    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    if (pool.last_stage == neostation::donation::Stage::snapshot_busy) return 0;
    if (NeoSwapExperimentProfile().configured && !pool.live_bytes) {
        NeoSwapCPUBufferStats cpu{};
        if (NeoSwap_CPUBufferSnapshot(&cpu) != NEOSWAP_OK || !cpu.enabled) return 0;
    }
    // Existing file allocations cannot become donor loans by filling an idle
    // pool. Only real donor use and the separate demand queue justify growth.
    // While relay host loans are admitted the controller lowers the floor to
    // zero so idle prepared donor pages are not duplicated relay capacity.
    return neostation::donation::adaptive_donation_target(pool.live_bytes,
        [self donorFloorBytes], [self donorReserveBytes],
        NeoSwapExperimentProfile().configured ? 16*kMiB : kDonationGrowthQuantumBytes,
        kDonationHardLimitBytes);
}
- (uint64_t)donorFloorBytes {
    if (NeoSwapExperimentProfile().configured) return 16*kMiB;
    return _budgetDecisionCount ? _budgetDecision.donor_floor_bytes : kDonationWarmFloorBytes;
}
- (uint64_t)donorReserveBytes {
    if (NeoSwapExperimentProfile().configured) return 32*kMiB;
    return _budgetDecisionCount ? _budgetDecision.donor_reserve_bytes : kDonationReserveBytes;
}
- (void)retireDonorsIfIdle {
    if (!self.donorSessions || NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return;
    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    if (pool.last_stage == neostation::donation::Stage::snapshot_busy || pool.live_blocks) return;
    const auto ended = neostation::donation::pool_campaign_end(self.donorEpoch);
    if (!ended) {
        self.donorGrowthRefusal = @{@"stage":[NSString stringWithUTF8String:
            neostation::donation::stage_name(ended.stage)], @"kernelResult":@(ended.kernel_result)};
        return;
    }
    NSArray* sessions = [self.donorSessions copy];
    self.donorSessions = nil;
    self.donorAdoptedChunks = nil;
    self.donorRetryAfter = nil;
    self.donorErrors = nil;
    self.donorLoggedStates = nil;
    self.donorPendingIndexes = nil;
    self.donorPendingMaximums = nil;
    self.donorDemand = (NeoSwapDonationDemand){};
    self.donorLaunchIndex = 0;
    self.donorCursor = 0;
    self.donorGrowthRefusal = nil;
    self.donorFallbackUntil = NSDate.distantPast;
    for (id object in sessions)
        if ([object isKindOfClass:NeoSwapDonorSession.class]) [(NeoSwapDonorSession*)object close];
    [self appendRecord:[self snapshot:@"donation_session_end"]];
}
- (void)advanceDonors {
    if (!self.donorSessions || !NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)) return;
    // The quarter-second small-CPU admission gate is applied by applyBudget
    // from the same kernel sample; dispatch warnings still close it at once.
    (void)neostation::donation::pool_collect_lost();
    if (NeoSwapExperimentProfile().configured && !self.donorDemand.bytes) {
        NeoSwapDonationDemand demand{};
        if (NeoSwap_ClaimDonationDemand(&demand) != NEOSWAP_OK) return;
        self.donorDemand = demand;
    }

    // Two helpers are enough to establish the warm floor quickly. Additional
    // donor processes are started only when the active pair cannot satisfy a
    // real RPCS3 demand or the adaptive target.
    const NSUInteger warmDonors = NeoSwapExperimentProfile().configured ? 1 : kDonationWarmDonorCount;
    while (self.donorLaunchIndex < warmDonors &&
           self.donorPendingIndexes.count < kDonationConcurrentGrowths) {
        const uint64_t budget = [self nextDonationBudget];
        if (!budget) return;
        const NSUInteger index = self.donorLaunchIndex++;
        [self launchDonor:index budget:budget];
    }
    if (self.donorPendingIndexes.count) return;

    for (NSUInteger index = 0; index < 8 && self.donorPendingIndexes.count < kDonationConcurrentGrowths; ++index) {
        id object = self.donorSessions[index];
        if (![object isKindOfClass:NeoSwapDonorSession.class]) continue;
        const auto status = [(NeoSwapDonorSession*)object snapshot];
        if ((status.state != NeoSwapDonorStateFailed && status.state != NeoSwapDonorStateClosed) ||
            [self.donorRetryAfter[index] timeIntervalSinceNow] > 0 ||
            !neostation::donation::pool_donor_restartable(self.donorEpoch, index)) continue;
        NSDictionary* diagnostics = [(NeoSwapDonorSession*)object diagnostics];
        neostation::donation::CleanupSnapshot cleanup{};
        neostation::donation::cleanup_snapshot(cleanup);
        if ([diagnostics[@"cleanupPending"] boolValue] || cleanup.pending_blocks) {
            self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
            if ([diagnostics[@"cleanupPending"] boolValue]) [(NeoSwapDonorSession*)object close];
            continue;
        }
        const uint64_t retryBudget = [self nextDonationBudget];
        self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
        if (!retryBudget) return;
        [self launchDonor:index budget:retryBudget];
    }
    if (self.donorPendingIndexes.count) return;

    if (!self.donorDemand.bytes) {
        NeoSwapDonationDemand demand{};
        if (NeoSwap_ClaimDonationDemand(&demand) != NEOSWAP_OK) return;
        self.donorDemand = demand;
    }
    if (self.donorDemand.bytes) {
        const uint64_t budget = [self nextDonationBudget];
        if (budget < self.donorDemand.bytes) {
            if (budget) self.donorGrowthRefusal = @{@"stage":@"insufficient_headroom_for_requested_buffer",
                @"requestedBytes":@(self.donorDemand.bytes), @"availableBytes":@(budget),
                @"requestSequence":@(self.donorDemand.sequence), @"kernelResult":@(KERN_RESOURCE_SHORTAGE)};
            return;
        }
        for (NSUInteger attempt = 0; attempt < 8; ++attempt) {
            const NSUInteger index = self.donorCursor++ % 8;
            id object = self.donorSessions[index];
            if (![object isKindOfClass:NeoSwapDonorSession.class] ||
                [self.donorPendingIndexes containsIndex:index] ||
                [self.donorRetryAfter[index] timeIntervalSinceNow] > 0) continue;
            NeoSwapDonorSession* session = object;
            const NeoSwapDonorSnapshot status = [session snapshot];
            if (status.state != NeoSwapDonorStateActive || status.verifiedChunkCount >= 64 ||
                status.growthState == NeoSwapDonorGrowthComplete) continue;
            if ([session requestNextChunkWithMaximumBytes:self.donorDemand.bytes]) {
                [self.donorPendingIndexes addIndex:index];
                self.donorPendingMaximums[index] = @(self.donorDemand.bytes);
                return;
            }
        }
        if (self.donorLaunchIndex < 8 &&
            self.donorPendingIndexes.count < kDonationConcurrentGrowths) {
            const uint64_t launchBudget = [self nextDonationBudget];
            if (launchBudget) {
                const NSUInteger index = self.donorLaunchIndex++;
                [self launchDonor:index budget:launchBudget];
            }
        }
        return;
    }

    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    const uint64_t adaptiveTarget = [self adaptiveDonationTarget];
    uint64_t pending = [self pendingDonationBytes];
    if (!adaptiveTarget || pool.prepared_bytes + pending >= adaptiveTarget) {
        self.donorGrowthRefusal = nil;
        return;
    }

    uint64_t budget = [self nextDonationBudget];
    if (!budget) return;
    while (self.donorPendingIndexes.count < kDonationConcurrentGrowths) {
        const uint64_t accounted = pool.prepared_bytes + pending;
        if (accounted >= adaptiveTarget) break;
        uint64_t remaining = adaptiveTarget - accounted;
        const BOOL fallback = [self.donorFallbackUntil timeIntervalSinceNow] > 0;
        uint64_t requested = fallback ? kDonationFallbackChunkBytes : kDonationPrimaryChunkBytes;
        if (remaining < requested) requested = remaining;
        requested -= requested % vm_page_size;
        if (requested < kMiB) break;
        if (budget < requested) {
            if (!fallback && budget >= kDonationFallbackChunkBytes && remaining >= kDonationFallbackChunkBytes)
                requested = kDonationFallbackChunkBytes;
            else if (remaining <= kDonationFallbackChunkBytes && budget >= remaining)
                requested = remaining - remaining % vm_page_size;
            else break;
        }

        NSUInteger chosen = NSNotFound;
        uint64_t bestHeadroom = 0;
        for (NSUInteger attempt = 0; attempt < 8; ++attempt) {
            const NSUInteger index = (self.donorCursor + attempt) % 8;
            id object = self.donorSessions[index];
            if (![object isKindOfClass:NeoSwapDonorSession.class] ||
                [self.donorPendingIndexes containsIndex:index] ||
                [self.donorRetryAfter[index] timeIntervalSinceNow] > 0) continue;
            const NeoSwapDonorSnapshot status = [(NeoSwapDonorSession*)object snapshot];
            if (status.state != NeoSwapDonorStateActive || status.verifiedChunkCount >= 64 ||
                status.growthState == NeoSwapDonorGrowthComplete) continue;
            if (chosen == NSNotFound || status.donorHeadroomBytes > bestHeadroom) {
                chosen = index;
                bestHeadroom = status.donorHeadroomBytes;
            }
        }
        if (chosen == NSNotFound) {
            if (self.donorLaunchIndex < 8 &&
                self.donorPendingIndexes.count < kDonationConcurrentGrowths) {
                const NSUInteger index = self.donorLaunchIndex++;
                [self launchDonor:index budget:budget];
            }
            break;
        }
        self.donorCursor = (chosen + 1) % 8;
        NeoSwapDonorSession* session = self.donorSessions[chosen];
        if (![session requestNextChunkWithMaximumBytes:requested]) {
            self.donorRetryAfter[chosen] = [NSDate dateWithTimeIntervalSinceNow:2];
            continue;
        }
        [self.donorPendingIndexes addIndex:chosen];
        self.donorPendingMaximums[chosen] = @(requested);
        pending += requested;
        budget = budget > requested ? budget - requested : 0;
        if (budget < kMiB) break;
    }
}
- (void)donorChanged:(NeoSwapDonorSession*)session index:(NSUInteger)index error:(NSError*)failure {
    if (index >= self.donorSessions.count || self.donorSessions[index] != session) return;
    // Notifications can have queued while the Session moved forward. Inspect
    // its current authenticated state before granting/revoking any new loans.
    const NeoSwapDonorSnapshot status = [session snapshot];
    const BOOL pending = [self.donorPendingIndexes containsIndex:index];
    NSString* errorKey = [NSString stringWithFormat:@"%lu", (unsigned long)index];
    if (failure) self.donorErrors[errorKey] = @{@"domain":failure.domain,
        @"code":@(failure.code), @"description":failure.localizedDescription};
    if ([failure.domain isEqualToString:@"NeoSwapDonation"] &&
        (failure.code == 3104 || (failure.code == 3103 && ![NeoSwapMachHandle isTransportAvailable])))
        self.donorRetryAfter[index] = NSDate.distantFuture; // an unavailable SPI cannot recover by respawning
    if (status.state == NeoSwapDonorStateActive) {
        neostation::donation::PoolDonorSnapshot pooled{};
        neostation::donation::pool_donor_snapshot(index, pooled);
        // A bounded cached read can overlap an allocation publication. This
        // sample grants nothing and must not revoke a valid donor generation.
        if (pooled.last_stage == neostation::donation::Stage::snapshot_busy) return;
        neostation::donation::Result result{};
        if (!pooled.generation || pooled.generation != status.generation) result = neostation::donation::pool_donor_begin(
            self.donorEpoch, index, status.generation, status.donorPID);
        uint64_t adopted = self.donorAdoptedChunks[index].unsignedLongLongValue;
        const uint64_t previous = adopted;
        uint64_t largestNewChunk = 0;
        while (result && adopted < status.verifiedChunkCount) {
            const uint64_t bytes = [session chunkCapacityBytes:adopted];
            neostation::donation::SendRight copied;
            result = copied.prepare();
            const mach_port_t entry = result ? [session copyMemoryEntryForChunk:adopted] : MACH_PORT_NULL;
            if (result && entry != MACH_PORT_NULL) result = copied.adopt(entry);
            if (result && (!bytes || entry == MACH_PORT_NULL)) result = {
                neostation::donation::Stage::retain_entry, KERN_INVALID_RIGHT};
            if (result) result = neostation::donation::pool_adopt_donor(self.donorEpoch,
                index, status.generation, adopted, entry, bytes);
            const auto released = copied.reset();
            if (!released) result = released;
            if (result) { ++adopted; largestNewChunk = MAX(largestNewChunk, bytes); }
        }
        neostation::donation::Footprint measured{};
        measured.physical = status.donorFootprintBytes;
        measured.nonvolatile = status.donorNonvolatileBytes;
        measured.nonvolatile_compressed = status.donorCompressedBytes;
        if (result) result = neostation::donation::pool_verify_donor(self.donorEpoch,
            index, status.generation, status.capacityBytes, measured,
            status.donatedResidentBytes, status.donatedCompressedBytes);
        for (uint64_t chunk = previous; result && chunk < adopted; ++chunk)
            if (![session acknowledgeVerifiedChunk:chunk]) result = {
                neostation::donation::Stage::pool_unready, KERN_FAILURE};
        if (result && adopted > previous && self.donorDemand.bytes && pending) {
            if (largestNewChunk >= self.donorDemand.bytes) {
                const int acknowledged = NeoSwap_AcknowledgeDonationDemand(self.donorDemand.sequence);
                if (acknowledged == NEOSWAP_OK) self.donorDemand = (NeoSwapDonationDemand){};
                else result = {neostation::donation::Stage::pool_unready, acknowledged};
            } else {
                self.donorGrowthRefusal = @{@"stage":@"verified_chunk_smaller_than_requested_buffer",
                    @"requestedBytes":@(self.donorDemand.bytes), @"actualBytes":@(largestNewChunk)};
                self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
            }
        }
        if (result) {
            self.donorAdoptedChunks[index] = @(adopted);
            // A replacement Session clears the slot's old failure only after
            // its authenticated chunks are retained, verified and acknowledged.
            // Keep a current callback error or refused growth visible.
            if (!failure && status.growthState != NeoSwapDonorGrowthRefused)
                [self.donorErrors removeObjectForKey:errorKey];
            if (pending && status.growthState == NeoSwapDonorGrowthRefused) {
                NSDictionary* diagnostics = [session diagnostics];
                self.donorErrors[errorKey] = @{
                    @"stage":diagnostics[@"growthStage"] ?: @"growth_refused",
                    @"requestedBytes":@(status.refusedBytes),
                    @"generation":@(status.generation)};
                self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
                if (self.donorPendingMaximums[index].unsignedLongLongValue > kDonationFallbackChunkBytes)
                    self.donorFallbackUntil = [NSDate dateWithTimeIntervalSinceNow:30];
            }
            if (pending && status.growthState != NeoSwapDonorGrowthRequested &&
                status.growthState != NeoSwapDonorGrowthPreparing) [self clearPendingDonor:index];
        } else {
            self.donorErrors[errorKey] = @{@"stage":[NSString stringWithUTF8String:
                neostation::donation::stage_name(result.stage)], @"kernelResult":@(result.kernel_result)};
            neostation::donation::pool_donor_lost(self.donorEpoch, index, status.generation, result.kernel_result);
            if (pending) [self clearPendingDonor:index];
            self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
            [session close];
        }
    } else if (status.state == NeoSwapDonorStateFailed || status.state == NeoSwapDonorStateClosed) {
        neostation::donation::pool_donor_lost(self.donorEpoch, index, status.generation, status.kernelResult);
        if ([self.donorRetryAfter[index] timeIntervalSinceNow] <= 0)
            self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
        if (pending) [self clearPendingDonor:index];
    }
    // Ledger heartbeats still update the pool each second. Persist structural
    // changes immediately, not two full identical ~9-KiB records per second;
    // regular samples retain resident/compressed movement every two seconds.
    if (!self.donorLoggedStates) self.donorLoggedStates = [NSMutableDictionary new];
    NSDictionary* logState = @{@"generation":@(status.generation), @"state":@(status.state),
        @"growth":@(status.growthState), @"chunks":@(status.verifiedChunkCount),
        @"capacity":@(status.capacityBytes), @"refused":@(status.refusedBytes),
        @"kernel":@(status.kernelResult), @"error":self.donorErrors[errorKey] ?: NSNull.null};
    if (![logState isEqual:self.donorLoggedStates[errorKey]]) {
        self.donorLoggedStates[errorKey] = logState;
        [self appendRecord:[self snapshot:@"donor_state"]];
    }
    [self advanceDonors];
}
#endif
- (void)applyBudget {
    using namespace neostation::budget;
    Inputs in{};
    in.session_active = NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3) != 0;
    in.physical_bytes = NSProcessInfo.processInfo.physicalMemory;
    task_vm_info_data_t memory{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS &&
        count >= TASK_VM_INFO_REV1_COUNT) {
        in.host_footprint_bytes = memory.phys_footprint;
        in.host_footprint_valid = true;
    }
    in.host_available_bytes = os_proc_available_memory();
    in.host_available_valid = in.host_available_bytes != 0 || TARGET_OS_SIMULATOR;
    in.dispatch_warning = self.cpuBufferPressureRaised;
    in.thermal_serious = NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious;
#if defined(NEOSWAP_DONATION)
    neostation::donation::SystemHeadroom system{};
    if (neostation::donation::system_headroom(system)) {
        in.system_usable_bytes = system.usable_bytes;
        in.system_valid = true;
    }
    in.system_pressure = static_cast<Pressure>(static_cast<uint32_t>(system.pressure));
    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    in.donors_available = pool.state == neostation::donation::PoolState::verified && pool.donor_count > 0;
    in.donor_prepared_bytes = pool.prepared_bytes;
    in.donor_live_bytes = pool.live_bytes;
#endif
#if defined(NEOSWAP_RELAY)
    if (NeoSwapExperimentProfile().relay()) {
        const auto* relay = NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI);
        NeoSwapRelayStats stats{}; stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_RELAY_ABI;
        if (relay && relay->snapshot(&stats) == NEOSWAP_RELAY_OK) {
            const auto owners = neostation::relay::backend().pressure_diagnostics();
            in.relay_ready = relay->enabled(0) != 0 && relay->enabled(neostation::relay::host_loan_owner) != 0;
            in.relay_capacity_bytes = stats.capacity_bytes;
            in.relay_guest_live_bytes = owners.owner_live_bytes[0];
            in.relay_host_live_bytes = owners.owner_live_bytes[neostation::relay::host_loan_owner];
        }
    }
#endif
    NeoSwapStats totals{}; totals.struct_size = sizeof(totals);
    NeoSwapHostStats host{};
    if (NeoSwap_Snapshot(&totals) == NEOSWAP_OK && NeoSwap_HostSnapshot(&host) == NEOSWAP_OK) {
        const uint64_t outside = host.relay_loan_live_bytes + host.owner_donated_live_bytes[NEOSWAP_RPCS3];
        in.file_live_bytes = totals.live_bytes > outside ? totals.live_bytes - outside : 0;
    }
#if defined(NEOSWAP_SHADER_STORAGE)
    id archived = [NeoSwapStorage_Diagnostics() valueForKeyPath:@"sourceArchive.videoPixelLiveArchivedBytes"];
    if ([archived isKindOfClass:NSNumber.class]) in.storage_archived_live_bytes = [archived unsignedLongLongValue];
#endif
    const Decision previous = _budgetDecision;
    const Decision decision = decide(in, previous);
    _budgetInputs = in;
    _budgetDecision = decision;
    ++_budgetDecisionCount;
    const uint64_t nowMs = static_cast<uint64_t>(NSProcessInfo.processInfo.systemUptime * 1000.0);
    // Apply: relay host-loan ceiling and admission (quota never below live),
    // the backend owner quota, the small-CPU gate, storage shrink and cache
    // maintenance. Existing loans are never revoked by any of these.
    const bool relayAdmitted = decision.host_loans_admitted && NeoSwapExperimentProfile().relay();
    const uint64_t quota = std::max(decision.host_loan_quota_bytes, in.relay_host_live_bytes);
    NeoSwap_SetRelayHostLoanPolicy(quota, relayAdmitted, relayAdmitted);
#if defined(NEOSWAP_RELAY)
    if (NeoSwapExperimentProfile().relay()) (void)NeoSwapRelay_SetHostLoanQuota(quota);
#endif
    NeoSwap_SetCPUBufferPressure(self.cpuBufferPressureRaised || !decision.small_cpu_admitted);
#if defined(NEOSWAP_SHADER_STORAGE)
    NeoSwapStorage_SetBudgetShrink(decision.storage_shrink_requested);
#endif
    (void)NeoSwap_RelayLoanMaintain(nowMs, !relayAdmitted);
    if (decision.state != previous.state || std::strcmp(decision.reason, previous.reason) != 0) {
        ++_budgetStateChanges;
        // Structural change only, at most four times per second by construction.
        if (in.session_active || previous.state != State::idle) {
            _budgetLastChangeMs = nowMs;
            [self appendRecord:[self snapshot:@"budget_decision"]];
        }
    }
}
- (int)configure:(NSInteger)capacity {
    NeoSwapConfig config{};
    config.struct_size = sizeof(config); config.abi_version = NEOSWAP_ABI;
    config.capacity_bytes = (uint64_t)capacity*kMiB;
    config.minimum_free_bytes = 2048*kMiB;
    config.minimum_allocation_bytes = kMiB;
    // RPCS3 is the only supported owner; legacy ABI slots stay disabled.
    config.enabled_owner_mask = 1u << NEOSWAP_RPCS3;
    int code = NeoSwap_Configure(self.directory.fileSystemRepresentation, &config);
    if (code == NEOSWAP_OK) { self.capacityMiB = capacity; self.configResult = NEOSWAP_OK; }
    return code;
}
- (NSDictionary*)snapshot:(NSString*)event {
    NeoSwapStats stats{}; stats.struct_size = sizeof(stats);
    NeoSwap_Snapshot(&stats);
    // This snapshot executes on the serial background diagnostics queue.
    NeoSwapHostStats host{}; NeoSwap_StorageSnapshot(&host);
    task_vm_info_data_t memory{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    kern_return_t kr = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count);
    const BOOL memoryValid = kr == KERN_SUCCESS && count >= TASK_VM_INFO_REV1_COUNT;
    _memorySamples.observe(memoryValid, memory.phys_footprint, memory.resident_size);
    task_events_info_data_t memoryEvents{};
    mach_msg_type_number_t eventCount = TASK_EVENTS_INFO_COUNT;
    const kern_return_t eventResult = task_info(mach_task_self(), TASK_EVENTS_INFO,
        (task_info_t)&memoryEvents, &eventCount);
    const BOOL eventsValid = eventResult == KERN_SUCCESS && eventCount >= TASK_EVENTS_INFO_COUNT;
    vm_statistics64_data_t systemMemory{};
    mach_msg_type_number_t systemCount = HOST_VM_INFO64_COUNT;
    const mach_port_t hostPort = mach_host_self();
    const kern_return_t systemResult = host_statistics64(hostPort, HOST_VM_INFO64,
        (host_info64_t)&systemMemory, &systemCount);
    if (hostPort != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), hostPort);
    const BOOL systemValid = systemResult == KERN_SUCCESS && systemCount >= HOST_VM_INFO64_COUNT;
    NSMutableArray* owners = [NSMutableArray new];
    NSArray* names = @[@"rpcs3",@"dolphin",@"armsx2",@"dusklight",@"kartpad",@"probe"];
    for (uint32_t i=0; i<NEOSWAP_OWNER_COUNT; ++i) {
        const auto& o = stats.owners[i];
        [owners addObject:@{@"owner":names[i], @"liveBytes":@(o.live_bytes),
            @"peakBytes":@(o.peak_bytes), @"allocationCount":@(o.allocation_count),
            @"rejectionCount":@(o.rejection_count),
            @"requestCount":@(o.allocation_count + o.rejection_count),
            @"lastResult":@(host.owner_last_result[i]),
            @"lastErrno":@(host.owner_last_errno[i]),
            @"registered":@((stats.registered_owner_mask & (1u << i)) != 0)}];
    }
    BOOL donationSupported = NO;
    id donatedMemory = NSNull.null;
    id donatedResident = NSNull.null;
    id donatedCompressed = NSNull.null;
    id donorFootprint = NSNull.null;
    id donorHeadroom = NSNull.null;
    id donorDiagnostics = NSNull.null;
    id donationPoolError = NSNull.null;
    uint32_t donorSessionState = 0;
    uint64_t donorCapacity = 0;
    id cleanupDiagnostics = NSNull.null;
    id donationWorkers = @[];
    id growthRefusal = NSNull.null;
    NSString* growthState = @"unavailable";
    uint64_t target = kDonationHardLimitBytes;
    // Non-donation builds must not reference the donation-only selector.
#if defined(NEOSWAP_DONATION)
    uint64_t adaptiveTarget = NeoSwap_OwnerSessionActive(NEOSWAP_RPCS3)
        ? [self adaptiveDonationTarget] : 0;
#else
    uint64_t adaptiveTarget = 0;
#endif
    uint64_t remaining = adaptiveTarget;
    uint64_t pendingGrowthCount = 0;
#if defined(NEOSWAP_DONATION)
    NSMutableArray* workers = [NSMutableArray new];
    uint64_t measuredHeadroom = 0;
    BOOL anyRefused = NO;
    for (NSUInteger index = 0; index < self.donorSessions.count; ++index) {
        id object = self.donorSessions[index];
        if (![object isKindOfClass:NeoSwapDonorSession.class]) continue;
        NeoSwapDonorSession* session = object;
        const NeoSwapDonorSnapshot status = [session snapshot];
        neostation::donation::PoolDonorSnapshot pooled{};
        neostation::donation::pool_donor_snapshot(index, pooled);
        if (pooled.state == neostation::donation::PoolState::verified &&
            (status.state != NeoSwapDonorStateActive || status.generation != pooled.generation ||
             status.donorPID != pooled.pid)) {
            neostation::donation::pool_donor_lost(self.donorEpoch, index, pooled.generation, status.kernelResult);
            neostation::donation::pool_donor_snapshot(index, pooled);
        }
        const BOOL ready = pooled.state == neostation::donation::PoolState::verified &&
            status.state == NeoSwapDonorStateActive && status.generation == pooled.generation &&
            status.donorPID == pooled.pid;
        if (ready) measuredHeadroom += status.donorHeadroomBytes;
        anyRefused |= status.growthState == NeoSwapDonorGrowthRefused;
        if ([self.donorPendingIndexes containsIndex:index]) donorSessionState = status.state;
        [workers addObject:@{@"index":@(index), @"pid":@(status.donorPID),
            @"generation":@(status.generation), @"state":@(status.state),
            @"growthState":@(status.growthState), @"targetBytes":@(status.targetBytes),
            @"verifiedChunkCount":@(pooled.verified_chunks), @"preparedBytes":@(pooled.prepared_bytes),
            @"retainedBytes":@(pooled.retained_bytes), @"liveBytes":@(pooled.live_bytes),
            @"residentBytes":ready ? @(pooled.resident_bytes) : NSNull.null,
            @"compressedBytes":ready ? @(pooled.compressed_bytes) : NSNull.null,
            @"headroomBytes":@(status.donorHeadroomBytes), @"refusedBytes":@(status.refusedBytes),
            @"diagnostics":[session diagnostics], @"error":self.donorErrors[
                [NSString stringWithFormat:@"%lu", (unsigned long)index]] ?: NSNull.null}];
    }
    neostation::donation::PoolSnapshot pool{};
    neostation::donation::pool_snapshot(pool);
    // Refresh the cached aggregate after fail-closed per-PID state checks above.
    NeoSwap_HostSnapshot(&host);
    donationSupported = pool.donor_count > 0;
    donorCapacity = pool.prepared_bytes;
    if (donationSupported) {
        donatedMemory = @(pool.resident_bytes + pool.compressed_bytes);
        donatedResident = @(pool.resident_bytes);
        donatedCompressed = @(pool.compressed_bytes);
        donorFootprint = @(pool.donor_footprint);
        donorHeadroom = @(measuredHeadroom);
        if (!self.donorPendingIndexes.count) donorSessionState = NeoSwapDonorStateActive;
    }
    donationWorkers = workers;
    donorDiagnostics = @{@"workers":workers};
    donationPoolError = self.donorErrors.count ? self.donorErrors : (id)NSNull.null;
    growthRefusal = self.donorGrowthRefusal ?: NSNull.null;
    remaining = pool.prepared_bytes < adaptiveTarget ? adaptiveTarget - pool.prepared_bytes : 0;
    pendingGrowthCount = self.donorPendingIndexes.count;
    const BOOL goalPending = adaptiveTarget && pool.prepared_bytes < adaptiveTarget;
    growthState = !adaptiveTarget ? @"idle" : !remaining ? @"ready" : self.donorPendingIndexes.count
        ? (self.donorDemand.bytes ? @"growing" : @"warming")
        : goalPending ? (self.donorGrowthRefusal || anyRefused ? @"limited" : @"warming")
        : @"waiting";
    neostation::donation::CleanupSnapshot cleanup{};
    neostation::donation::cleanup_snapshot(cleanup);
    cleanupDiagnostics = @{@"pendingBlocks":@(cleanup.pending_blocks),
        @"pendingMappings":@(cleanup.pending_mappings), @"pendingRights":@(cleanup.pending_rights),
        @"stage":[NSString stringWithUTF8String:neostation::donation::stage_name(cleanup.last_stage)],
        @"kernelResult":@(cleanup.last_kernel_result)};
#endif
    NeoSwapCPUBufferStats cpuBuffers{};
    NeoSwap_CPUBufferSnapshot(&cpuBuffers);
    NeoSwapRelayLoanStats relayLoans{};
    NeoSwap_RelayLoanSnapshot(&relayLoans);
#if defined(NEOSWAP_TESTING)
    const BOOL diagnosticProbesAvailable = YES;
#else
    const BOOL diagnosticProbesAvailable = NO;
#endif
    const auto& in = _budgetInputs;
    const auto& decision = _budgetDecision;
    // One view of what RPCS3 holds and what NeoSwap supplies outside the host
    // footprint. Capacity, aliases and cumulative counters are excluded; the
    // physical residency of relay and donor pages is not measured here.
    NSDictionary* contribution = @{
        @"schema":@1,
        @"hostFootprintBytes":in.host_footprint_valid ? @(in.host_footprint_bytes) : NSNull.null,
        @"hostAvailableBytes":in.host_available_valid ? @(in.host_available_bytes) : NSNull.null,
        @"relayGuestLiveBytes":@(in.relay_guest_live_bytes),
        @"relayHostLoanLiveBytes":@(in.relay_host_live_bytes),
        @"donorLoanLiveBytes":@(in.donor_live_bytes),
        @"mobilizedOutsideFootprintBytes":@(decision.mobilized_bytes),
        @"fileFallbackLiveBytes":@(in.file_live_bytes),
        @"storageArchivedLiveBytes":@(in.storage_archived_live_bytes),
        @"neoswapTotalBytes":@(decision.neoswap_total_bytes),
        @"residencyMeasured":@NO,
        @"definition":@"live backing intervals charged outside the host process footprint plus file-backed and archived bytes; not resident RAM"};
    NSDictionary* budget = @{
        @"schema":@1, @"decisions":@(_budgetDecisionCount), @"stateChanges":@(_budgetStateChanges),
        @"state":[NSString stringWithUTF8String:neostation::budget::state_name(decision.state)],
        @"reason":[NSString stringWithUTF8String:decision.reason],
        @"operationalReserveBytes":@(decision.operational_reserve_bytes),
        @"growthRoomBytes":@(decision.growth_room_bytes),
        @"guestReserveBytes":@(decision.guest_reserve_bytes),
        @"hostLoanQuotaBytes":@(decision.host_loan_quota_bytes),
        @"hostLoansAdmitted":@(decision.host_loans_admitted),
        @"smallCpuAdmitted":@(decision.small_cpu_admitted),
        @"donorFloorBytes":@(decision.donor_floor_bytes),
        @"donorReserveBytes":@(decision.donor_reserve_bytes),
        @"donorGrowthAdmitted":@(decision.donor_growth_admitted),
        @"storageShrinkRequested":@(decision.storage_shrink_requested),
        @"inputs":@{
            @"sessionActive":@(in.session_active), @"physicalBytes":@(in.physical_bytes),
            @"systemUsableBytes":in.system_valid ? @(in.system_usable_bytes) : NSNull.null,
            @"systemPressure":@(static_cast<uint32_t>(in.system_pressure)),
            @"dispatchWarning":@(in.dispatch_warning), @"thermalSerious":@(in.thermal_serious),
            @"relayReady":@(in.relay_ready), @"relayCapacityBytes":@(in.relay_capacity_bytes),
            @"donorsAvailable":@(in.donors_available), @"donorPreparedBytes":@(in.donor_prepared_bytes)},
        @"relayHostLoans":@{
            @"available":@(relayLoans.available), @"admitted":@(relayLoans.admitted),
            @"videoFramesAdmitted":@(relayLoans.video_frames_admitted),
            @"quotaBytes":@(relayLoans.quota_bytes), @"liveBytes":@(relayLoans.live_bytes),
            @"peakBytes":@(relayLoans.peak_bytes), @"liveBlocks":@(relayLoans.live_blocks),
            @"allocationCount":@(relayLoans.allocation_count), @"reuseHits":@(relayLoans.reuse_hits),
            @"cachedBytes":@(relayLoans.cached_bytes), @"cachedBlocks":@(relayLoans.cached_blocks),
            @"cacheFlushes":@(relayLoans.cache_flushes), @"paddingBytes":@(relayLoans.padding_bytes),
            @"policyRefusals":@(relayLoans.policy_refusals), @"quotaRefusals":@(relayLoans.quota_refusals),
            @"backendRefusals":@(relayLoans.backend_refusals), @"releaseFailures":@(relayLoans.release_failures),
            @"lastBackendResult":@(relayLoans.last_backend_result),
            @"kindLiveBytes":@{@"cpuData":@(relayLoans.kind_live_bytes[1]), @"cpuCache":@(relayLoans.kind_live_bytes[2]),
                @"gpuHostVisible":@(relayLoans.kind_live_bytes[3]), @"videoFrame":@(relayLoans.kind_live_bytes[4])},
            @"kindLiveBlocks":@{@"cpuData":@(relayLoans.kind_live_blocks[1]), @"cpuCache":@(relayLoans.kind_live_blocks[2]),
                @"gpuHostVisible":@(relayLoans.kind_live_blocks[3]), @"videoFrame":@(relayLoans.kind_live_blocks[4])},
            @"kindAllocations":@{@"cpuData":@(relayLoans.kind_allocation_count[1]), @"cpuCache":@(relayLoans.kind_allocation_count[2]),
                @"gpuHostVisible":@(relayLoans.kind_allocation_count[3]), @"videoFrame":@(relayLoans.kind_allocation_count[4])},
            @"kindRefusals":@{@"cpuData":@(relayLoans.kind_refusal_count[1]), @"cpuCache":@(relayLoans.kind_refusal_count[2]),
                @"gpuHostVisible":@(relayLoans.kind_refusal_count[3]), @"videoFrame":@(relayLoans.kind_refusal_count[4])}}};
    return @{@"scope":@"rpcs3_only", @"diagnosticProbesAvailable":@(diagnosticProbesAvailable),
        @"schema":@1, @"event":event, @"timestamp":@([NSDate date].timeIntervalSince1970),
        @"experiment":@{@"mode":[NSString stringWithUTF8String:NeoSwapExperimentProfile().name()],
            @"valid":@(NeoSwapExperimentProfile().valid), @"configured":@(NeoSwapExperimentProfile().configured),
            @"sourceCommit":[NSBundle.mainBundle objectForInfoDictionaryKey:@"NeoSwapResearchSource"] ?: NSNull.null,
            @"relay":@(NeoSwapExperimentProfile().relay()), @"donors":@(NeoSwapExperimentProfile().donors()),
            @"storage":@(NeoSwapExperimentProfile().storage()), @"changesRequireProcessRestart":@YES},
        @"iosMemoryWarningCount":@(self.iosWarningCount),
        @"thermalState":@(NSProcessInfo.processInfo.thermalState),
        @"budget":budget, @"neoswapContribution":contribution,
        @"terminationCause":NSNull.null, @"jetsamConfirmed":@NO,
        @"processMemoryEvents":@{@"valid":@(eventsValid), @"kernelResult":@(eventResult),
            @"faults":eventsValid ? @(memoryEvents.faults) : NSNull.null,
            @"pageins":eventsValid ? @(memoryEvents.pageins) : NSNull.null,
            @"cowFaults":eventsValid ? @(memoryEvents.cow_faults) : NSNull.null,
            @"zeroFills":NSNull.null, @"zeroFillsAvailable":@NO,
            @"scope":@"process_lifetime_kernel_counters_not_NeoSwap_restores"},
        @"systemMemory":@{@"valid":@(systemValid), @"kernelResult":@(systemResult), @"pageBytes":@(vm_page_size),
            @"freeBytes":systemValid ? @(uint64_t(systemMemory.free_count)*vm_page_size) : NSNull.null,
            @"activeBytes":systemValid ? @(uint64_t(systemMemory.active_count)*vm_page_size) : NSNull.null,
            @"inactiveBytes":systemValid ? @(uint64_t(systemMemory.inactive_count)*vm_page_size) : NSNull.null,
            @"wiredBytes":systemValid ? @(uint64_t(systemMemory.wire_count)*vm_page_size) : NSNull.null,
            @"compressorBytes":systemValid ? @(uint64_t(systemMemory.compressor_page_count)*vm_page_size) : NSNull.null,
            @"freeIsNotProcessHeadroom":@YES},
        @"cpuBufferExperiment":@{
            @"enabled":@(cpuBuffers.enabled), @"pressureRaised":@(cpuBuffers.pressure_raised),
            @"minimumBytes":@65536, @"maximumExclusiveBytes":@1048576,
            @"liveBudgetBytes":@(512 * kMiB), @"slotBudget":@768, @"diskFallback":@NO,
            @"requests":@(cpuBuffers.requests), @"requestedBytes":@(cpuBuffers.requested_bytes),
            @"successfulAllocations":@(cpuBuffers.successful_allocations),
            @"fallbackCount":@(cpuBuffers.fallback_count), @"liveBytes":@(cpuBuffers.live_bytes),
            @"peakBytes":@(cpuBuffers.peak_bytes), @"liveBlocks":@(cpuBuffers.live_blocks),
            @"allocatedBytes":@(cpuBuffers.allocated_bytes), @"pressureRefusals":@(cpuBuffers.pressure_refusals),
            @"policyRefusals":@(cpuBuffers.policy_refusals), @"poolMisses":@(cpuBuffers.pool_misses),
            @"requestBins":@[@(cpuBuffers.request_bins[0]), @(cpuBuffers.request_bins[1]),
                @(cpuBuffers.request_bins[2]), @(cpuBuffers.request_bins[3])],
            @"donatedBins":@[@(cpuBuffers.donated_bins[0]), @(cpuBuffers.donated_bins[1]),
                @(cpuBuffers.donated_bins[2]), @(cpuBuffers.donated_bins[3])]},
        @"pid":@(getpid()), @"build":NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"unknown",
        @"capacityMiB":@(self.capacityMiB), @"configResult":@(self.configResult),
        @"capacityBytes":@(stats.capacity_bytes), @"liveBytes":@(stats.live_bytes),
        @"peakBytes":@(stats.peak_bytes), @"allocatedDiskBytes":@(stats.allocated_disk_bytes),
        @"reservedVirtualBytes":@(host.reserved_virtual_bytes),
        @"reservationResult":@(host.reservation_result), @"reservationErrno":@(host.reservation_errno),
        @"storageFreeBytes":@(host.disk_free_bytes), @"remainingStorageBytes":@(host.remaining_storage_bytes),
        // Live shared loans, measured helper pages and untouched pool capacity
        // are different quantities. No amount is inferred from the 8 GiB quota.
        @"memoryDonationSupported":@(donationSupported), @"donatedMemoryBytes":donatedMemory,
        @"donatedClientBytes":@(host.owner_donated_live_bytes[NEOSWAP_RPCS3]),
        @"donationTargetBytes":@(adaptiveTarget), @"donationGoalBytes":@(target),
        @"donationHardLimitBytes":@(kDonationHardLimitBytes),
        @"donationWarmFloorBytes":@([self donorFloorBytes]),
        @"donationReserveBytes":@([self donorReserveBytes]),
        @"donationTargetBasis":@"active_donor_loans_plus_bounded_reserve",
        @"donationUnusedPreparedBytes":@(host.donor_prepared_bytes -
            MIN(host.donor_prepared_bytes, host.donated_live_bytes)),
        @"donationGrowthQuantumBytes":@(NeoSwapExperimentProfile().configured ? 16*kMiB : kDonationGrowthQuantumBytes),
        @"donationPrimaryChunkBytes":@(kDonationPrimaryChunkBytes),
        @"donationFallbackChunkBytes":@(kDonationFallbackChunkBytes),
        @"donationConcurrentGrowths":@(kDonationConcurrentGrowths),
        @"donationPendingGrowthCount":@(pendingGrowthCount),
        @"donationRemainingBytes":@(remaining),
        @"donorCount":@(host.donor_count), @"donorLostCount":@(host.donor_lost_count),
        @"donationRetainedBytes":@(host.donor_retained_bytes),
        @"donationRetainedLiveBytes":@(host.donor_retained_live_bytes),
        @"donationGrowthState":growthState, @"donationGrowthRefusal":growthRefusal,
        @"donationPendingDemandBytes":@(host.donor_pending_demand_bytes),
        @"donationInflightDemandBytes":@(host.donor_inflight_demand_bytes),
        @"donationPendingDemandCount":@(host.donor_pending_demand_count),
        @"donationDemandOverflowCount":@(host.donor_demand_overflow_count),
        @"donationWorkers":donationWorkers,
        @"donationPreparedBytes":@(host.donor_prepared_bytes), @"donorCapacityBytes":@(donorCapacity),
        @"donatedResidentBytes":donatedResident, @"donatedCompressedBytes":donatedCompressed,
        @"donorFootprintBytes":donorFootprint, @"donorHeadroomBytes":donorHeadroom,
        @"donationState":@(host.donation_state), @"donorSessionState":@(donorSessionState),
        @"donorPID":@(host.donor_pid), @"donorGeneration":@(host.donor_generation),
        @"donationLastStage":@(host.donation_last_stage),
        @"donationLastKernelResult":@(host.donation_last_kernel_result),
        @"donationDiagnostics":donorDiagnostics,
        @"donationPoolError":donationPoolError,
        @"donationCleanup":cleanupDiagnostics,
        @"hostEffectiveMemoryEntitlements":NeoSwapEffectivePermissions(),
        @"allocationCount":@(stats.allocation_count), @"liveBlocks":@(stats.live_blocks),
        @"rejectionCount":@(stats.rejection_count), @"ioErrors":@(stats.io_errors),
        @"maxAllocationTimeUs":@(stats.max_allocation_time_us), @"allocationTimeUs":@(stats.allocation_time_us),
        @"lastResult":@(stats.last_result), @"lastErrno":@(stats.last_errno),
        @"processFootprintBytes":memoryValid ? @(memory.phys_footprint) : NSNull.null,
        @"processResidentBytes":memoryValid ? @(memory.resident_size) : NSNull.null,
        @"processCompressedLedgerBytes":memoryValid ? @(memory.compressed) : NSNull.null,
        @"memoryProfile":@{
            @"schema":@1, @"sampledSessionActive":@(_memorySamples.active()),
            @"sessionSequence":@(_memorySamples.session()), @"sessionElapsedMs":@(_memorySamples.elapsed_ms()),
            @"intervalMs":@(_memorySamples.active() ? _memorySamples.active_interval_ms : _memorySamples.idle_interval_ms),
            @"validSamples":@(_memorySamples.valid_samples()), @"measurementValid":@(memoryValid),
            @"taskInfoKernelResult":@(kr),
            @"footprintPeakBytes":_memorySamples.valid_samples() ? @(_memorySamples.footprint_peak()) : NSNull.null,
            @"residentPeakBytes":_memorySamples.valid_samples() ? @(_memorySamples.resident_peak()) : NSNull.null,
            @"footprintDeltaBytes":_memorySamples.delta_valid() ? @(_memorySamples.footprint_delta()) : NSNull.null,
            @"pressureMask":@(_memorySamples.pressure_level()),
            @"pressureEvents":@(_memorySamples.pressure_events()), @"pressureChanges":@(_memorySamples.pressure_changes()),
            @"sampledPeakOnly":@YES, @"automaticTraining":@NO,
            @"maximumRowBytes":@(_memorySamples.maximum_row_bytes),
            @"maximumRetainedLogBytes":@(2 * _memorySamples.maximum_file_bytes)},
        @"processAvailableBytes":@(os_proc_available_memory()),
        @"memoryHeadroomPolicy":TARGET_OS_SIMULATOR ? @"macOS-hosted simulator; iOS process limit unavailable" : @"iOS process headroom above256MiB required for capacity test",
        @"physicalMemoryBytes":@(NSProcessInfo.processInfo.physicalMemory),
        @"osVersion":NSProcessInfo.processInfo.operatingSystemVersionString,
#if defined(NEOSWAP_RELAY)
        @"guestRelay":NeoSwapRelay_Diagnostics(),
#endif
#if defined(NEOSWAP_SHADER_STORAGE)
        @"shaderStorage":NeoSwapStorage_Diagnostics(),
#endif
        @"owners":owners, @"diagnosticPath":self.diagnosticPath ?: @"", @"operationPath":self.operationPath ?: @"",
        @"diagnosticErrno":@(self.diagnosticErrno), @"diagnosticError":self.diagnosticError ?: NSNull.null};
}
- (void)appendRecord:(NSDictionary*)record {
    [self appendRecord:record toPath:self.diagnosticPath];
}
- (void)appendRecord:(NSDictionary*)record toPath:(NSString*)path {
    NSData* data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data || !path.length) return;
    using neostation::diagnostics::MemorySamples;
    if (data.length >= MemorySamples::maximum_row_bytes) { self.diagnosticErrno = EOVERFLOW; return; }
    NSFileManager* fm = NSFileManager.defaultManager;
    unsigned long long size = [[fm attributesOfItemAtPath:path error:nil] fileSize];
    if (size > MemorySamples::maximum_file_bytes - (data.length + 1)) {
        NSString* previous = [path stringByAppendingString:@".previous"];
        NSError* error = nil;
        if ([fm fileExistsAtPath:previous] && ![fm removeItemAtPath:previous error:&error]) {
            [self preserveDiagnosticError:error]; return;
        }
        if (![fm moveItemAtPath:path toPath:previous error:&error]) {
            [self preserveDiagnosticError:error]; return;
        }
    }
    int fd = open(path.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW, 0600);
    if (fd < 0) { self.diagnosticErrno = errno; return; }
    NSMutableData* line = [data mutableCopy]; const char newline = '\n'; [line appendBytes:&newline length:1];
    const char* bytes = (const char*)line.bytes;
    size_t remaining = line.length;
    while (remaining) {
        ssize_t n = write(fd, bytes, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { self.diagnosticErrno = n < 0 ? errno : EIO; break; }
        bytes += n; remaining -= (size_t)n;
    }
    close(fd);
}
- (void)preserveDiagnosticError:(NSError*)error {
    NSError* underlying = error.userInfo[NSUnderlyingErrorKey];
    NSError* posix = [error.domain isEqual:NSPOSIXErrorDomain] ? error :
        [underlying.domain isEqual:NSPOSIXErrorDomain] ? underlying : nil;
    self.diagnosticErrno = posix ? (int)posix.code : EIO;
    self.diagnosticError = error ? @{@"domain":error.domain, @"code":@(error.code),
        @"detail":error.localizedDescription, @"underlyingDomain":underlying.domain ?: @"",
        @"underlyingCode":underlying ? @(underlying.code) : NSNull.null} : nil;
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
#if defined(NEOSWAP_SHADER_STORAGE)
    if ([call.method isEqualToString:@"setShaderStorage"]) {
        id flag = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[@"enabled"] : nil;
        if (![flag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flag) != CFBooleanGetTypeID()) {
            result([FlutterError errorWithCode:@"invalid_argument" message:@"enabled must be a boolean" details:nil]);
            return;
        }
        dispatch_async(self.queue, ^{
            NeoSwapStorage_SetPreference([flag boolValue]);
            NSMutableDictionary* response = [[self snapshot:@"shader_storage_preference"] mutableCopy];
            response[@"result"] = @0; [self appendRecord:response];
            dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
        });
        return;
    }
#endif
    if (![call.method isEqualToString:@"snapshot"] &&
        ![call.method isEqualToString:@"probe"] && ![call.method isEqualToString:@"capacityProbe"]) { result(FlutterMethodNotImplemented); return; }
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            int code = NEOSWAP_OK;
#if !defined(NEOSWAP_TESTING)
            // Distributed apps never create synthetic allocations from settings.
            if (![call.method isEqualToString:@"snapshot"]) code = NEOSWAP_DISABLED;
#else
            if ([call.method isEqualToString:@"probe"]) {
                // Bounded functional check. It is NOT a fake game allocation or a RAM-limit benchmark.
                void* address = nullptr;
                const auto* api = NeoSwap_GetAPI(NEOSWAP_ABI);
                code = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, 8*kMiB, 65536, &address);
                if (code == NEOSWAP_OK) {
                    auto* p = (unsigned char*)address;
                    for (uint64_t i=0; i<8*kMiB; ++i) p[i] = (unsigned char)((i*131+(i>>12)*17)^0x9d);
                    code = api->sync(address);
                    if (code == NEOSWAP_OK) for (uint64_t i=0; i<8*kMiB; ++i)
                        if (p[i] != (unsigned char)((i*131+(i>>12)*17)^0x9d)) { code = NEOSWAP_IO; break; }
                    int freed = api->release(address);
                    if (freed != NEOSWAP_OK) code = freed;
                }
            } else if ([call.method isEqualToString:@"capacityProbe"]) {
                self.lastCapacityProbe=nil;
                id size=[call.arguments isKindOfClass:NSDictionary.class]?call.arguments[@"sizeMiB"]:nil;
                NSInteger amount=[size isKindOfClass:NSNumber.class]?[size integerValue]:0;
                NeoSwapStats active{};active.struct_size=sizeof(active);NeoSwap_Snapshot(&active);
                if(![size isKindOfClass:NSNumber.class] || [size doubleValue]!=amount ||
                   ![@[@64,@128,@512,@1024,@2048,@4096,@8192] containsObject:@(amount)])code=NEOSWAP_INVALID;
                else if(active.live_blocks)code=NEOSWAP_BUSY;
                else if(uint64_t(amount)*kMiB>active.capacity_bytes)code=NEOSWAP_QUOTA;
                else {
                    NSMutableArray* samples=[NSMutableArray array];
                    code=NeoSwapCapacityProbe(NeoSwap_GetAPI(1),uint64_t(amount)*kMiB,
                      [&](const char* phase,uint64_t bytes){
                        NSMutableDictionary* row=[[self snapshot:@"capacity_probe"] mutableCopy];
                        row[@"phase"]=[NSString stringWithUTF8String:phase];row[@"testedBytes"]=@(bytes);
                        [samples addObject:row];[self appendRecord:row];
                      },[]{return NeoSwapCapacityHeadroom(os_proc_available_memory(),TARGET_OS_SIMULATOR!=0);});
                    self.lastCapacityProbe=@{@"requestedBytes":@(uint64_t(amount)*kMiB),@"result":@(code),
                      @"dataVerified":@(code==NEOSWAP_OK),@"samples":samples,
                      @"kind":@"file-backed data capacity; not physical RAM or a donation test"};
                }
            }
#endif
            if (![call.method isEqualToString:@"snapshot"]) {
                NSMutableDictionary* event = [[self snapshot:call.method] mutableCopy];
                event[@"result"] = @(code); [self appendRecord:event];
            }
            NSMutableDictionary* response = [[self snapshot:@"snapshot"] mutableCopy];
            response[@"result"] = @(code);
            if(self.lastCapacityProbe)response[@"capacityProbe"]=self.lastCapacityProbe;
            dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
        }
    });
}
@end
