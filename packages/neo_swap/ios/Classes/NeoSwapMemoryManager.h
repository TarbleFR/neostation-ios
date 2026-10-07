// SPDX-License-Identifier: MIT
#ifndef NeoSwapMemoryManager_h
#define NeoSwapMemoryManager_h

#import <Foundation/Foundation.h>

@interface NeoSwapMemoryManager : NSObject

+ (instancetype)sharedManager;

// Allocate maximum memory with proper jetsam handling
- (BOOL)allocateMaximumMemory:(uint64_t)sizeBytes;

// Release memory with proper cleanup
- (void)releaseMemory:(uint64_t)sizeBytes;

// Check if we can allocate more memory without triggering jetsam
- (BOOL)canAllocateMoreMemory:(uint64_t)sizeBytes;

// Get current memory usage statistics
- (NSDictionary *)memoryStatistics;

// Setup memory pressure monitoring
- (void)setupMemoryPressureMonitoring;

// Set up proper entitlements for memory management
- (void)setupMemoryEntitlements;

@end

#endif /* NeoSwapMemoryManager_h */