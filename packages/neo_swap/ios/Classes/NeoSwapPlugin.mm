#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>

static NSString* const kCapacity = @"NeoSwapCapacityMiBV1";
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
@end

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
    NSInteger stored = [NSUserDefaults.standardUserDefaults integerForKey:kCapacity];
    self.capacityMiB = (stored == 512 || stored == 1024 || stored == 2048) ? stored : 0;
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
        self.configResult = created ? [self configure:self.capacityMiB] : NEOSWAP_STORAGE;
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
            NSDictionary* row = [strongSelf snapshot:@"sample"];
            uint64_t count = [row[@"allocationCount"] unsignedLongLongValue];
            // Disabled sessions do not generate periodic disk activity.
            if ([row[@"capacityBytes"] unsignedLongLongValue] ||
                [row[@"liveBytes"] unsignedLongLongValue] || count != strongSelf.lastAllocationCount)
                [strongSelf appendRecord:row];
            strongSelf.lastAllocationCount = count;
        }
    });
    dispatch_resume(self.timer);
    return self;
}
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
            @"registered":@((stats.registered_owner_mask & (1u << i)) != 0)}];
    }
    return @{@"schema":@1, @"event":event, @"timestamp":@([NSDate date].timeIntervalSince1970),
        @"pid":@(getpid()), @"capacityMiB":@(self.capacityMiB), @"configResult":@(self.configResult),
        @"capacityBytes":@(stats.capacity_bytes), @"liveBytes":@(stats.live_bytes),
        @"peakBytes":@(stats.peak_bytes), @"allocatedDiskBytes":@(stats.allocated_disk_bytes),
        @"allocationCount":@(stats.allocation_count), @"liveBlocks":@(stats.live_blocks),
        @"rejectionCount":@(stats.rejection_count), @"ioErrors":@(stats.io_errors),
        @"maxAllocationTimeUs":@(stats.max_allocation_time_us), @"allocationTimeUs":@(stats.allocation_time_us),
        @"lastResult":@(stats.last_result), @"lastErrno":@(stats.last_errno),
        @"processFootprintBytes":kr == KERN_SUCCESS ? @(memory.phys_footprint) : NSNull.null,
        @"processResidentBytes":kr == KERN_SUCCESS ? @(memory.resident_size) : NSNull.null,
        @"processAvailableBytes":@(os_proc_available_memory()),
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
    if (![call.method isEqualToString:@"snapshot"] && ![call.method isEqualToString:@"configure"] &&
        ![call.method isEqualToString:@"probe"]) { result(FlutterMethodNotImplemented); return; }
    dispatch_async(self.queue, ^{
        @autoreleasepool {
            int code = NEOSWAP_OK;
            if ([call.method isEqualToString:@"configure"]) {
                id value = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments[@"capacityMiB"] : nil;
                BOOL numeric = [value isKindOfClass:NSNumber.class];
                NSInteger requested = numeric ? [value integerValue] : -1;
                if (!numeric || [value doubleValue] != (double)requested ||
                    !(requested == 0 || requested == 512 || requested == 1024 || requested == 2048)) code = NEOSWAP_INVALID;
                else {
                    code = [self configure:requested];
                    if (code == NEOSWAP_OK) [NSUserDefaults.standardUserDefaults setInteger:requested forKey:kCapacity];
                }
            } else if ([call.method isEqualToString:@"probe"]) {
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
            }
            if (![call.method isEqualToString:@"snapshot"]) {
                NSMutableDictionary* event = [[self snapshot:call.method] mutableCopy];
                event[@"result"] = @(code); [self appendRecord:event];
            }
            NSMutableDictionary* response = [[self snapshot:@"snapshot"] mutableCopy];
            response[@"result"] = @(code);
            dispatch_async(dispatch_get_main_queue(), ^{ result(response); });
        }
    });
}
@end
