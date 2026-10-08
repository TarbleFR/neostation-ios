// SPDX-License-Identifier: MIT
#import "NeoSwapMemoryManager.h"
#import <TargetConditionals.h>
#if TARGET_OS_IOS
#import <UIKit/UIKit.h>
#endif
#include <mach/mach.h>
#include <os/proc.h>
#include <algorithm>
#include <atomic>
#include <dispatch/dispatch.h>
#include <limits>

#ifdef NEOSWAP_TESTING
static std::atomic<uint64_t> testingAvailableMemory{UINT64_MAX};
#endif
static uint64_t availableMemory() {
#ifdef NEOSWAP_TESTING
    const uint64_t value = testingAvailableMemory.load();
    if (value != UINT64_MAX) return value;
#endif
    return os_proc_available_memory();
}

// Compatibility helper for explicit virtual reservations. RPCS3 continues to
// use the canonical NeoSwap broker, donor and relay; this is never run at boot.
// A successful reservation is not proof of resident RAM or protection from jetsam.
@interface NeoSwapMemoryManager ()
@property(nonatomic, strong) NSMutableArray<NSMutableDictionary*>* reservations;
@property(nonatomic, strong) dispatch_source_t pressureSource;
@property(nonatomic, assign) uint64_t reservedBytes;
@property(nonatomic, assign) BOOL pressureRaised;
@end

@implementation NeoSwapMemoryManager
+ (instancetype)sharedManager {
    static NeoSwapMemoryManager* instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[self alloc] init]; });
    return instance;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        self.reservations = [NSMutableArray new];
        [self setupMemoryPressureMonitoring];
    }
    return self;
}
- (uint64_t)targetAllocationSize { return 7ULL * 1024 * 1024 * 1024; }
- (BOOL)canAllocateMoreMemory:(uint64_t)sizeBytes {
    @synchronized(self) {
        const uint64_t target = [self targetAllocationSize];
        const uint64_t margin = 64ULL * 1024 * 1024;
        const uint64_t available = availableMemory();
        return sizeBytes && !self.pressureRaised && self.reservedBytes <= target &&
            sizeBytes <= target - self.reservedBytes &&
            available > margin && sizeBytes <= available - margin;
    }
}
- (BOOL)allocateMaximumMemory:(uint64_t)sizeBytes {
    @synchronized(self) {
        const uint64_t page = vm_page_size;
        if (!page || sizeBytes > std::numeric_limits<uint64_t>::max() - (page - 1)) return NO;
        const uint64_t bytes = ((sizeBytes + page - 1) / page) * page;
        if (![self canAllocateMoreMemory:bytes]) return NO;
        vm_address_t address = 0;
        if (vm_allocate(mach_task_self(), &address, (vm_size_t)bytes, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
            return NO;
        [self.reservations addObject:[@{@"address":@(address), @"bytes":@(bytes)} mutableCopy]];
        self.reservedBytes += bytes;
        return YES;
    }
}
- (void)releaseMemory:(uint64_t)sizeBytes {
    @synchronized(self) {
        // Retire complete private reservations. On kernel failure ownership and
        // counters remain intact for a later retry; no caller has a data pointer.
        uint64_t remaining = sizeBytes;
        for (NSInteger i = (NSInteger)self.reservations.count - 1; i >= 0 && remaining; --i) {
            NSDictionary* block = self.reservations[(NSUInteger)i];
            const uint64_t bytes = [block[@"bytes"] unsignedLongLongValue];
            const vm_address_t address = (vm_address_t)[block[@"address"] unsignedLongLongValue];
            if (vm_deallocate(mach_task_self(), address, (vm_size_t)bytes) != KERN_SUCCESS) continue;
            [self.reservations removeObjectAtIndex:(NSUInteger)i];
            self.reservedBytes -= bytes;
            remaining -= std::min(remaining, bytes);
        }
    }
}
- (void)setupMemoryPressureMonitoring {
    @synchronized(self) {
        if (self.pressureSource) return;
        self.pressureSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
            DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL,
            dispatch_get_main_queue());
        __weak NeoSwapMemoryManager* weakSelf = self;
        dispatch_source_set_event_handler(self.pressureSource, ^{
            NeoSwapMemoryManager* owner = weakSelf;
            if (!owner) return;
            const unsigned long level = dispatch_source_get_data(owner.pressureSource);
            @synchronized(owner) {
                owner.pressureRaised = (level & (DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL)) != 0;
                if (owner.pressureRaised) [owner releaseMemory:UINT64_MAX];
            }
        });
        dispatch_resume(self.pressureSource);
#if TARGET_OS_IOS
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handleMemoryPressure:)
            name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
#endif
    }
}
- (void)handleMemoryPressure:(NSNotification*)notification {
    (void)notification;
    [self releaseMemory:UINT64_MAX];
}
- (NSDictionary*)memoryStatistics {
    @synchronized(self) {
        return @{@"totalMemory":@(NSProcessInfo.processInfo.physicalMemory),
                 @"maxAllocatableMemory":@([self targetAllocationSize]),
                 @"reservedMemory":@(self.reservedBytes), @"allocatedMemory":@(self.reservedBytes),
                 @"availableMemory":@(availableMemory()),
                 @"targetAllocationSize":@([self targetAllocationSize]),
                 @"residentMemory":NSNull.null, @"pressureRaised":@(self.pressureRaised)};
    }
}
- (void)setupMemoryEntitlements {
    // Capabilities are requested and granted at signing, never at runtime.
}
- (BOOL)allocateTargetMemory { return [self allocateMaximumMemory:[self targetAllocationSize]]; }
- (BOOL)initializeMemorySystem {
    // Initializing diagnostics does not reserve or touch 7 GiB.
    return self.reservations != nil;
}
- (NSString*)allocationStatus { return [[self memoryStatistics] description]; }
#ifdef NEOSWAP_TESTING
+ (void)setTestingAvailableMemory:(uint64_t)bytes { testingAvailableMemory.store(bytes); }
- (NSArray<NSNumber*>*)testingReservationAddresses {
    @synchronized(self) {
        NSMutableArray<NSNumber*>* addresses = [NSMutableArray new];
        for (NSDictionary* block in self.reservations) [addresses addObject:block[@"address"]];
        return addresses;
    }
}
#endif
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (_pressureSource) dispatch_source_cancel(_pressureSource);
    for (NSDictionary* block in _reservations)
        vm_deallocate(mach_task_self(), (vm_address_t)[block[@"address"] unsignedLongLongValue],
            (vm_size_t)[block[@"bytes"] unsignedLongLongValue]);
}
@end
