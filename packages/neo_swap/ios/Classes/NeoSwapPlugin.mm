#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
#include "NeoSwapHost.h"
#include "NeoSwapCapacityProbe.h"
#if defined(NEOSWAP_RELAY)
#import "NeoSwapRelayService.h"
#endif
#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <dlfcn.h>
#if defined(NEOSWAP_DONATION)
#import "Donation/NeoSwapDonorIPC.h"
#include "Donation/Pool.h"
#endif

static NSString* const kDiagnostic = @"NeoSwap-v1.jsonl";
static const uint64_t kMiB = 1024 * 1024;

@interface NeoSwapPlugin ()
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, strong) dispatch_source_t timer;
@property(nonatomic, copy) NSString* directory;
@property(nonatomic, copy) NSString* diagnosticPath;
@property(nonatomic, assign) NSInteger capacityMiB;
@property(nonatomic, assign) int configResult;
@property(nonatomic, assign) uint64_t lastAllocationCount;
#if defined(NEOSWAP_RELAY)
@property(nonatomic, assign) uint64_t lastRelayLiveBytes;
@property(nonatomic, copy) NSString* lastRelayState;
#endif
@property(nonatomic, assign) int diagnosticErrno;
@property(nonatomic, strong) NSDictionary* lastCapacityProbe;
#if defined(NEOSWAP_DONATION)
@property(nonatomic, strong) NSMutableArray* donorSessions;
@property(nonatomic, strong) NSMutableArray<NSNumber*>* donorAdoptedChunks;
@property(nonatomic, strong) NSMutableArray<NSDate*>* donorRetryAfter;
@property(nonatomic, strong) NSMutableDictionary* donorErrors;
@property(nonatomic, strong) NSDictionary* donorGrowthRefusal;
@property(nonatomic, assign) uint64_t donorEpoch;
@property(nonatomic, assign) NSInteger donorPendingIndex;
@property(nonatomic, assign) NSUInteger donorLaunchIndex;
@property(nonatomic, assign) NSUInteger donorCursor;
@property(nonatomic, assign) NeoSwapDonationDemand donorDemand;
@property(nonatomic, assign) uint64_t donorGenerationCounter;
#endif
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
    // Runtime policy, not an optional user feature. Old Off/budget preferences
    // cannot disable the integrated service after an update or relaunch.
    self.capacityMiB = 8192;
#if defined(NEOSWAP_RELAY)
    NeoSwapRelay_Start();
#endif
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
#if defined(NEOSWAP_DONATION)
        [self startDonors];
#endif
        [self appendRecord:[self snapshot:@"process_start"]];
    });
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.queue);
    dispatch_source_set_timer(self.timer, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC),
        2*NSEC_PER_SEC, NSEC_PER_SEC/4);
    __weak NeoSwapPlugin* weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        @autoreleasepool {
#if defined(NEOSWAP_DONATION)
            (void)neostation::donation::retry_cleanup();
            [strongSelf advanceDonors];
#endif
#if defined(NEOSWAP_RELAY)
            NeoSwapRelay_Maintain();
#endif
            NSDictionary* row = [strongSelf snapshot:@"sample"];
            uint64_t count = [row[@"allocationCount"] unsignedLongLongValue];
#if defined(NEOSWAP_RELAY)
            const uint64_t relayLive = [row[@"guestRelay"][@"liveBackingBytes"] unsignedLongLongValue];
            NSString* relayState = row[@"guestRelay"][@"state"] ?: @"unknown";
            const BOOL relayChanged = relayLive != strongSelf.lastRelayLiveBytes ||
                ![relayState isEqualToString:strongSelf.lastRelayState];
            strongSelf.lastRelayLiveBytes = relayLive;
            strongSelf.lastRelayState = relayState;
#else
            const uint64_t relayLive = 0;
            const BOOL relayChanged = NO;
#endif
            // Automatic availability does not imply an active game. Avoid
            // periodic disk writes while the integrated allocator is idle.
            if ([row[@"liveBytes"] unsignedLongLongValue] || relayLive || relayChanged || count != strongSelf.lastAllocationCount)
                [strongSelf appendRecord:row];
            strongSelf.lastAllocationCount = count;
        }
    });
    dispatch_resume(self.timer);
    return self;
}
#if defined(NEOSWAP_DONATION)
- (void)startDonors {
    if (self.donorSessions) return;
    self.donorEpoch = 1;
    self.donorGenerationCounter = self.donorEpoch * 16;
    self.donorPendingIndex = -1;
    self.donorSessions = [NSMutableArray new];
    self.donorAdoptedChunks = [NSMutableArray new];
    self.donorRetryAfter = [NSMutableArray new];
    self.donorErrors = [NSMutableDictionary new];
    for (NSUInteger index = 0; index < 8; ++index) {
        [self.donorSessions addObject:NSNull.null];
        [self.donorAdoptedChunks addObject:@0];
        [self.donorRetryAfter addObject:NSDate.distantPast];
    }
    auto begun = neostation::donation::pool_campaign_begin(self.donorEpoch, uint64_t(8192)*kMiB);
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
    neostation::donation::SystemHeadroom system{};
    const auto sampled = neostation::donation::system_headroom(system);
    // phys_footprint includes uncompressed-page equivalents of compressed
    // memory. It is a diagnostic ledger, not free physical RAM to subtract.
    uint64_t available = sampled ? system.usable_bytes : 0;
    available = MIN(available, pool.target_bytes - pool.retained_bytes);
    available -= available % vm_page_size;
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
        requestedBytes:uint64_t(8192)*kMiB generation:++self.donorGenerationCounter
        timeout:10 observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot ignored, NSError* failure) {
        (void)ignored;
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{ [strongSelf donorChanged:source index:index error:failure]; });
    }];
    const uint64_t first = MIN(budget, kMiB);
    if (![session setInitialChunkMaximumBytes:first]) {
        self.donorErrors[[NSString stringWithFormat:@"%lu", (unsigned long)index]] =
            @{@"stage":@"initial_chunk_budget", @"bytes":@(first)};
        return;
    }
    self.donorSessions[index] = session;
    self.donorAdoptedChunks[index] = @0;
    self.donorPendingIndex = index;
    [session start];
}
- (void)advanceDonors {
    if (!self.donorSessions || self.donorPendingIndex >= 0) return;
    (void)neostation::donation::pool_collect_lost();
    if (self.donorLaunchIndex < 8) {
        const uint64_t budget = [self nextDonationBudget];
        if (!budget) return;
        const NSUInteger index = self.donorLaunchIndex++;
        [self launchDonor:index budget:budget];
        return;
    }
    for (NSUInteger index = 0; index < 8; ++index) {
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
            continue; // keep the old Session until proof/right cleanup actually succeeds
        }
        const uint64_t retryBudget = [self nextDonationBudget];
        self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
        if (!retryBudget) return;
        [self launchDonor:index budget:retryBudget];
        return;
    }
    NeoSwapDonationDemand demand{};
    if (NeoSwap_ClaimDonationDemand(&demand) != NEOSWAP_OK) return;
    self.donorDemand = demand;
    if (!demand.bytes) {
        self.donorGrowthRefusal = nil;
        return; // Never fill idle device RAM merely to reach the target.
    }
    const uint64_t budget = [self nextDonationBudget];
    if (budget < demand.bytes) {
        if (budget) self.donorGrowthRefusal = @{@"stage":@"insufficient_headroom_for_requested_buffer",
            @"requestedBytes":@(demand.bytes), @"availableBytes":@(budget),
            @"requestSequence":@(demand.sequence), @"kernelResult":@(KERN_RESOURCE_SHORTAGE)};
        return; // A loan cannot span several smaller donated objects.
    }
    for (NSUInteger attempt = 0; attempt < 8; ++attempt) {
        const NSUInteger index = self.donorCursor++ % 8;
        id object = self.donorSessions[index];
        if (![object isKindOfClass:NeoSwapDonorSession.class]) continue;
        NeoSwapDonorSession* session = object;
        const NeoSwapDonorSnapshot status = [session snapshot];
        if (status.state != NeoSwapDonorStateActive || status.verifiedChunkCount >= 64 ||
            status.growthState == NeoSwapDonorGrowthComplete ||
            [self.donorRetryAfter[index] timeIntervalSinceNow] > 0) continue;
        const uint64_t maximum = demand.bytes;
        if ([session requestNextChunkWithMaximumBytes:maximum]) {
            self.donorPendingIndex = index;
            return;
        }
    }
}
- (void)donorChanged:(NeoSwapDonorSession*)session index:(NSUInteger)index error:(NSError*)failure {
    if (index >= self.donorSessions.count || self.donorSessions[index] != session) return;
    // Notifications can have queued while the Session moved forward. Inspect
    // its current authenticated state before granting/revoking any new loans.
    const NeoSwapDonorSnapshot status = [session snapshot];
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
        if (result && adopted > previous && self.donorDemand.bytes &&
            self.donorPendingIndex == (NSInteger)index) {
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
            if (self.donorPendingIndex == (NSInteger)index && status.growthState == NeoSwapDonorGrowthRefused)
                self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
            if (self.donorPendingIndex == (NSInteger)index &&
                status.growthState != NeoSwapDonorGrowthRequested &&
                status.growthState != NeoSwapDonorGrowthPreparing) self.donorPendingIndex = -1;
        } else {
            self.donorErrors[errorKey] = @{@"stage":[NSString stringWithUTF8String:
                neostation::donation::stage_name(result.stage)], @"kernelResult":@(result.kernel_result)};
            neostation::donation::pool_donor_lost(self.donorEpoch, index, status.generation, result.kernel_result);
            if (self.donorPendingIndex == (NSInteger)index) self.donorPendingIndex = -1;
            self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
            [session close];
        }
    } else if (status.state == NeoSwapDonorStateFailed || status.state == NeoSwapDonorStateClosed) {
        neostation::donation::pool_donor_lost(self.donorEpoch, index, status.generation, status.kernelResult);
        if ([self.donorRetryAfter[index] timeIntervalSinceNow] <= 0)
            self.donorRetryAfter[index] = [NSDate dateWithTimeIntervalSinceNow:30];
        if (self.donorPendingIndex == (NSInteger)index) self.donorPendingIndex = -1;
    }
    [self appendRecord:[self snapshot:@"donor_state"]];
    [self advanceDonors];
}
#endif
- (int)configure:(NSInteger)capacity {
    NeoSwapConfig config{};
    config.struct_size = sizeof(config); config.abi_version = NEOSWAP_ABI;
    config.capacity_bytes = (uint64_t)capacity*kMiB;
    config.minimum_free_bytes = 2048*kMiB;
    config.minimum_allocation_bytes = kMiB;
    // V1 production adapter: RPCS3 CPU-side RSX data; the probe is kept separate.
    // Other owners are implemented in the broker, but not claimed as core integrations.
    config.enabled_owner_mask = (1u << NEOSWAP_RPCS3) | (1u << NEOSWAP_PROBE);
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
    uint64_t target = uint64_t(8192)*kMiB;
    uint64_t remaining = target;
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
        if (self.donorPendingIndex == (NSInteger)index) donorSessionState = status.state;
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
        if (self.donorPendingIndex < 0) donorSessionState = NeoSwapDonorStateActive;
    }
    donationWorkers = workers;
    donorDiagnostics = @{@"workers":workers};
    donationPoolError = self.donorErrors.count ? self.donorErrors : (id)NSNull.null;
    growthRefusal = self.donorGrowthRefusal ?: NSNull.null;
    remaining = pool.prepared_bytes < target ? target - pool.prepared_bytes : 0;
    growthState = !remaining ? @"complete" : self.donorPendingIndex >= 0 ? @"growing" :
        self.donorLaunchIndex >= 8 && pool.donor_count && !self.donorDemand.bytes && !host.donor_pending_demand_bytes
            ? @"waiting" : self.donorGrowthRefusal || anyRefused ? @"limited" : @"idle";
    neostation::donation::CleanupSnapshot cleanup{};
    neostation::donation::cleanup_snapshot(cleanup);
    cleanupDiagnostics = @{@"pendingBlocks":@(cleanup.pending_blocks),
        @"pendingMappings":@(cleanup.pending_mappings), @"pendingRights":@(cleanup.pending_rights),
        @"stage":[NSString stringWithUTF8String:neostation::donation::stage_name(cleanup.last_stage)],
        @"kernelResult":@(cleanup.last_kernel_result)};
#endif
    return @{@"schema":@1, @"event":event, @"timestamp":@([NSDate date].timeIntervalSince1970),
        @"pid":@(getpid()), @"capacityMiB":@(self.capacityMiB), @"configResult":@(self.configResult),
        @"capacityBytes":@(stats.capacity_bytes), @"liveBytes":@(stats.live_bytes),
        @"peakBytes":@(stats.peak_bytes), @"allocatedDiskBytes":@(stats.allocated_disk_bytes),
        @"reservedVirtualBytes":@(host.reserved_virtual_bytes),
        @"reservationResult":@(host.reservation_result), @"reservationErrno":@(host.reservation_errno),
        @"storageFreeBytes":@(host.disk_free_bytes), @"remainingStorageBytes":@(host.remaining_storage_bytes),
        // Live shared loans, measured helper pages and untouched pool capacity
        // are different quantities. No amount is inferred from the 8 GiB quota.
        @"memoryDonationSupported":@(donationSupported), @"donatedMemoryBytes":donatedMemory,
        @"donatedClientBytes":@(host.owner_donated_live_bytes[NEOSWAP_RPCS3]),
        @"donationTargetBytes":@(target), @"donationRemainingBytes":@(remaining),
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
        @"processFootprintBytes":kr == KERN_SUCCESS ? @(memory.phys_footprint) : NSNull.null,
        @"processResidentBytes":kr == KERN_SUCCESS ? @(memory.resident_size) : NSNull.null,
        @"processAvailableBytes":@(os_proc_available_memory()),
        @"memoryHeadroomPolicy":TARGET_OS_SIMULATOR ? @"macOS-hosted simulator; iOS process limit unavailable" : @"iOS process headroom above256MiB required for capacity test",
        @"physicalMemoryBytes":@(NSProcessInfo.processInfo.physicalMemory),
        @"osVersion":NSProcessInfo.processInfo.operatingSystemVersionString,
#if defined(NEOSWAP_RELAY)
        @"guestRelay":NeoSwapRelay_Diagnostics(),
#endif
        @"owners":owners, @"diagnosticPath":self.diagnosticPath ?: @"",
        @"diagnosticErrno":@(self.diagnosticErrno)};
}
- (void)appendRecord:(NSDictionary*)record {
    NSData* data = [NSJSONSerialization dataWithJSONObject:record options:NSJSONWritingSortedKeys error:nil];
    if (!data || !self.diagnosticPath.length) return;
    NSFileManager* fm = NSFileManager.defaultManager;
    unsigned long long size = [[fm attributesOfItemAtPath:self.diagnosticPath error:nil] fileSize];
    if (size > 2*1024*1024) {
        NSString* previous = [self.diagnosticPath stringByAppendingString:@".previous"];
        [fm removeItemAtPath:previous error:nil];
        [fm moveItemAtPath:self.diagnosticPath toPath:previous error:nil];
    }
    int fd = open(self.diagnosticPath.fileSystemRepresentation, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC|O_NOFOLLOW, 0600);
    if (fd < 0) { self.diagnosticErrno = errno; return; }
    NSMutableData* line = [data mutableCopy]; const char newline = '\n'; [line appendBytes:&newline length:1];
    const char* bytes = (const char*)line.bytes;
    size_t remaining = line.length;
    while (remaining) {
        ssize_t n = write(fd, bytes, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { self.diagnosticErrno = errno; break; }
        bytes += n; remaining -= (size_t)n;
    }
    close(fd);
}
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
    if (![call.method isEqualToString:@"snapshot"] &&
        ![call.method isEqualToString:@"probe"] && ![call.method isEqualToString:@"capacityProbe"]) { result(FlutterMethodNotImplemented); return; }
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            int code = NEOSWAP_OK;
            if ([call.method isEqualToString:@"probe"]) {
                // Bounded functional check. It is NOT a fake game allocation or a RAM-limit benchmark.
                void* address = nullptr;
                const auto* api = NeoSwap_GetAPI(NEOSWAP_ABI);
                code = api->allocate(NEOSWAP_PROBE, NEOSWAP_CPU_DATA, 8*kMiB, 65536, &address);
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
