#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
#include "NeoSwapHost.h"
#include "NeoSwapCapacityProbe.h"
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
@property(nonatomic, assign) int diagnosticErrno;
@property(nonatomic, strong) NSDictionary* lastCapacityProbe;
#if defined(NEOSWAP_DONATION)
@property(nonatomic, strong) NeoSwapDonorSession* donorSession;
@property(nonatomic, assign) uint64_t donorPoolGeneration;
@property(nonatomic, strong) NSDictionary* donorError;
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
        [self startDonor];
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
#endif
            NSDictionary* row = [strongSelf snapshot:@"sample"];
            uint64_t count = [row[@"allocationCount"] unsignedLongLongValue];
            // Automatic availability does not imply an active game. Avoid
            // periodic disk writes while the integrated allocator is idle.
            if ([row[@"liveBytes"] unsignedLongLongValue] || count != strongSelf.lastAllocationCount)
                [strongSelf appendRecord:row];
            strongSelf.lastAllocationCount = count;
        }
    });
    dispatch_resume(self.timer);
    return self;
}
#if defined(NEOSWAP_DONATION)
- (void)startDonor {
    NSString* bundleID = NSBundle.mainBundle.bundleIdentifier;
    if (!bundleID.length || self.donorSession) return;
    NSString* identifier = [bundleID stringByAppendingString:@".neoswapdonor"];
    __weak NeoSwapPlugin* weakSelf = self;
    self.donorSession = [[NeoSwapDonorSession alloc] initWithHelperIdentifier:identifier
        requestedBytes:64*kMiB generation:1 timeout:10 observer:^(NeoSwapDonorSession* session,
            NeoSwapDonorSnapshot status, NSError* failure) {
        NeoSwapPlugin* strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(strongSelf.queue, ^{
            if (session != strongSelf.donorSession) return;
            if (failure) strongSelf.donorError = @{@"domain":failure.domain,
                @"code":@(failure.code), @"description":failure.localizedDescription};
            if (status.state == NeoSwapDonorStateActive) {
                neostation::donation::Footprint measured{};
                measured.physical = status.donorFootprintBytes;
                measured.nonvolatile = status.donorNonvolatileBytes;
                measured.nonvolatile_compressed = status.donorCompressedBytes;
                if (strongSelf.donorPoolGeneration != status.generation) {
                    auto result = neostation::donation::pool_begin(status.generation,
                        status.donorPID, uint64_t(8192)*kMiB);
                    mach_port_t entry = result ? [session copyMemoryEntry] : MACH_PORT_NULL;
                    if (result && entry == MACH_PORT_NULL)
                        result = {neostation::donation::Stage::retain_entry, KERN_INVALID_RIGHT};
                    if (result) result = neostation::donation::pool_adopt(status.generation,
                        entry, status.capacityBytes);
                    if (entry != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), entry);
                    if (result) result = neostation::donation::pool_verified(status.generation, measured);
                    if (result) strongSelf.donorPoolGeneration = status.generation;
                    else {
                        strongSelf.donorError = @{@"stage":[NSString stringWithUTF8String:
                            neostation::donation::stage_name(result.stage)],
                            @"kernelResult":@(result.kernel_result)};
                        neostation::donation::pool_lost(status.generation, result.kernel_result);
                        [session close];
                    }
                } else neostation::donation::pool_footprint(status.generation, measured);
            } else if (status.state == NeoSwapDonorStateFailed || status.state == NeoSwapDonorStateClosed) {
                neostation::donation::pool_lost(status.generation, status.kernelResult);
            }
            [strongSelf appendRecord:[strongSelf snapshot:@"donor_state"]];
        });
    }];
    [self.donorSession start];
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
#if defined(NEOSWAP_DONATION)
    NeoSwapDonorSnapshot donor{};
    if (self.donorSession) donor = [self.donorSession snapshot];
    donorSessionState = donor.state;
    donorCapacity = donor.capacityBytes;
    donationSupported = host.donation_state == static_cast<int32_t>(neostation::donation::PoolState::verified) &&
        donor.state == NeoSwapDonorStateActive && donor.generation == host.donor_generation &&
        donor.donorPID == host.donor_pid && donor.capacityBytes == host.donor_prepared_bytes &&
        donor.donatedCompressedBytes <= donor.capacityBytes &&
        donor.donatedResidentBytes <= donor.capacityBytes - donor.donatedCompressedBytes;
    if (donationSupported) {
        donatedMemory = @(donor.donatedResidentBytes + donor.donatedCompressedBytes);
        donatedResident = @(donor.donatedResidentBytes);
        donatedCompressed = @(donor.donatedCompressedBytes);
        donorFootprint = @(donor.donorFootprintBytes);
        donorHeadroom = @(donor.donorHeadroomBytes);
    }
    donorDiagnostics = self.donorSession ? [self.donorSession diagnostics] : @{};
    donationPoolError = self.donorError ?: NSNull.null;
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
        @"donatedClientBytes":@(host.donated_live_bytes),
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
