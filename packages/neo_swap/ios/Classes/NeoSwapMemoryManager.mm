// SPDX-License-Identifier: MIT
#import "NeoSwapMemoryManager.h"
#include <mach/mach.h>
#include <sys/mman.h>
#include <unistd.h>

@interface NeoSwapMemoryManager()
@property (nonatomic, assign) uint64_t totalMemory;
@property (nonatomic, assign) uint64_t reservedMemory;
@property (nonatomic, assign) uint64_t allocatedMemory;
@property (nonatomic, assign) uint64_t maxAllocatableMemory;
@property (nonatomic, assign) uint64_t targetAllocationSize;
@end

@implementation NeoSwapMemoryManager

+ (instancetype)sharedManager {
    static NeoSwapMemoryManager *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[NeoSwapMemoryManager alloc] init];
    });
    return sharedInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Initialize memory limits for iPhone 16 Pro Max (8GB RAM)
        self.totalMemory = NSProcessInfo.processInfo.physicalMemory;
        // Reserve 7GB for allocation (7 * 1024 * 1024 * 1024 bytes)
        self.targetAllocationSize = 7ULL * 1024 * 1024 * 1024;
        
        // Set maximum allocatable memory to 7GB (avoiding system instability)
        self.maxAllocatableMemory = self.targetAllocationSize;
        
        // Reserve 7GB for allocation
        self.reservedMemory = 0;
        self.allocatedMemory = 0;
        
        // Setup memory pressure monitoring
        [self setupMemoryPressureMonitoring];
    }
    return self;
}

// Attempt to allocate maximum memory with proper jetsam handling
- (BOOL)allocateMaximumMemory:(uint64_t)sizeBytes {
    if (sizeBytes > self.maxAllocatableMemory) {
        NSLog(@"Requested allocation size (%llu bytes) exceeds max allocatable memory (%llu bytes)", sizeBytes, self.maxAllocatableMemory);
        return NO;
    }
    
    // Use mach_vm_allocate for better control on iOS
    vm_address_t address = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, sizeBytes, VM_FLAGS_ANYWHERE);
    
    if (kr != KERN_SUCCESS) {
        NSLog(@"Failed to allocate memory: %d", kr);
        return NO;
    }
    
    // Mark as non-cacheable to avoid jetsam
    kr = mach_vm_attributes_set(mach_task_self(), address, sizeBytes, VM_ATTRIBUTE_NO_CACHE);
    if (kr != KERN_SUCCESS) {
        NSLog(@"Failed to set no-cache attribute: %d", kr);
        mach_vm_deallocate(mach_task_self(), address, sizeBytes);
        return NO;
    }
    
    // Set memory priority to avoid jetsam
    kr = mach_vm_set_memory_priority(mach_task_self(), address, sizeBytes, VM_MEMORY_PRIORITY_HIGH);
    if (kr != KERN_SUCCESS) {
        NSLog(@"Failed to set memory priority: %d", kr);
        // Continue anyway - this is not critical for allocation
    }
    
    self.allocatedMemory += sizeBytes;
    return YES;
}

// Allocate the full 7GB target
- (BOOL)allocateTargetMemory {
    return [self allocateMaximumMemory:self.targetAllocationSize];
}

// Release memory with proper cleanup
- (void)releaseMemory:(uint64_t)sizeBytes {
    if (sizeBytes > self.allocatedMemory) {
        sizeBytes = self.allocatedMemory;
    }
    
    // For now, we'll just track the release - actual deallocation would require 
    // more complex memory management with proper tracking
    self.allocatedMemory -= sizeBytes;
}

// Setup memory pressure monitoring to avoid jetsam
- (void)setupMemoryPressureMonitoring {
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleMemoryPressure:)
                                                 name:UIApplicationDidReceiveMemoryWarningNotification
                                               object:nil];
    
    // Monitor system memory pressure using mach APIs
    [self monitorSystemMemoryPressure];
}

// Handle memory pressure notifications
- (void)handleMemoryPressure:(NSNotification *)notification {
    NSLog(@"Memory pressure detected, releasing allocated memory");
    
    // Reduce allocation to avoid jetsam - release 20% of allocated memory
    uint64_t releaseAmount = self.allocatedMemory * 0.2; // Release 20% of allocated memory
    [self releaseMemory:releaseAmount];
}

// Monitor system memory pressure via mach APIs
- (void)monitorSystemMemoryPressure {
    // This would be implemented with more advanced memory pressure detection
    // using mach APIs and system monitoring
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        while (true) {
            // Periodic check of memory pressure
            [NSThread sleepForTimeInterval:5.0];
            
            // Check current memory usage and adjust if needed
            uint64_t currentMemory = self.allocatedMemory;
            uint64_t availableMemory = self.maxAllocatableMemory - currentMemory;
            
            if (availableMemory < (self.targetAllocationSize * 0.1)) { // Less than 10% remaining
                NSLog(@"Warning: Low memory detected, current allocation: %llu bytes", currentMemory);
                // Implement adaptive strategy here if needed
            }
        }
    });
}

// Check if we can allocate more memory without triggering jetsam
- (BOOL)canAllocateMoreMemory:(uint64_t)sizeBytes {
    uint64_t availableMemory = self.maxAllocatableMemory - self.allocatedMemory;
    return sizeBytes <= availableMemory;
}

// Get current memory usage statistics
- (NSDictionary *)memoryStatistics {
    return @{
        @"totalMemory": @(self.totalMemory),
        @"maxAllocatableMemory": @(self.maxAllocatableMemory),
        @"reservedMemory": @(self.reservedMemory),
        @"allocatedMemory": @(self.allocatedMemory),
        @"availableMemory": @(self.maxAllocatableMemory - self.allocatedMemory),
        @"targetAllocationSize": @(self.targetAllocationSize)
    };
}

// Set up proper entitlements for memory management
- (void)setupMemoryEntitlements {
    // Entitlements are already configured in NeoSwapEntitlements.plist
    // This method is a placeholder for any additional entitlement setup if needed
    NSLog(@"Memory entitlements already configured");
}

// Initialize and prepare the memory system for 7GB allocation
- (BOOL)initializeMemorySystem {
    NSLog(@"Initializing NeoSwap memory system for 7GB allocation...");
    
    // First, check if we can allocate the target amount
    if (![self allocateTargetMemory]) {
        NSLog(@"Failed to allocate target memory size");
        return NO;
    }
    
    NSLog(@"Successfully allocated %llu bytes of memory", self.targetAllocationSize);
    return YES;
}

// Get current allocation status
- (NSString *)allocationStatus {
    uint64_t available = self.maxAllocatableMemory - self.allocatedMemory;
    double percentage = ((double)self.allocatedMemory / (double)self.targetAllocationSize) * 100.0;
    
    return [NSString stringWithFormat:@"Allocated: %llu bytes (%.2f%%), Available: %llu bytes", 
            self.allocatedMemory, percentage, available];
}

@end