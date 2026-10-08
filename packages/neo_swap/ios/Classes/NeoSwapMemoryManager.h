// SPDX-License-Identifier: MIT
#ifndef NeoSwapMemoryManager_h
#define NeoSwapMemoryManager_h
#import <Foundation/Foundation.h>

// Explicit experimental virtual reservations, separate from the emulator broker.
// The 7 GiB ceiling is not a physical-RAM entitlement or a startup allocation.
@interface NeoSwapMemoryManager : NSObject
+ (instancetype)sharedManager;
- (BOOL)allocateMaximumMemory:(uint64_t)sizeBytes;
- (void)releaseMemory:(uint64_t)sizeBytes;
- (BOOL)canAllocateMoreMemory:(uint64_t)sizeBytes;
- (NSDictionary*)memoryStatistics;
- (void)setupMemoryPressureMonitoring;
- (void)setupMemoryEntitlements;
- (BOOL)allocateTargetMemory;
- (BOOL)initializeMemorySystem;
- (NSString*)allocationStatus;
#ifdef NEOSWAP_TESTING
+ (void)setTestingAvailableMemory:(uint64_t)bytes;
- (NSArray<NSNumber*>*)testingReservationAddresses;
#endif
@end
#endif
