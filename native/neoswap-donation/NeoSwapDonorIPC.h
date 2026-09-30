#pragma once

#import <Foundation/Foundation.h>
#import "NeoSwapMachHandle.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(uint32_t, NeoSwapDonorState) {
  NeoSwapDonorStateIdle,
  NeoSwapDonorStateLaunching,
  NeoSwapDonorStateVerifying,
  NeoSwapDonorStateActive,
  NeoSwapDonorStateClosed,
  NeoSwapDonorStateFailed,
};

typedef NS_ENUM(uint32_t, NeoSwapDonorGrowthState) {
  NeoSwapDonorGrowthIdle,
  NeoSwapDonorGrowthRequested,
  NeoSwapDonorGrowthPreparing,
  NeoSwapDonorGrowthRefused,
  NeoSwapDonorGrowthComplete,
};

typedef struct NeoSwapDonorSnapshot {
  uint64_t generation;
  uint64_t targetBytes;
  uint64_t capacityBytes;
  uint64_t verifiedChunkCount;
  uint64_t refusedBytes;
  uint64_t donatedResidentBytes;
  uint64_t donatedCompressedBytes;
  uint64_t donorFootprintBytes;
  uint64_t donorNonvolatileBytes;
  uint64_t donorCompressedBytes;
  uint64_t donorHeadroomBytes;
  int32_t donorPID;
  int32_t kernelResult;
  NeoSwapDonorState state;
  NeoSwapDonorGrowthState growthState;
} NeoSwapDonorSnapshot;

// This narrow protocol is on our separate anonymous auxiliary connection. It
// does not modify any Foundation global decoder allowlist or other JIT helper.
@protocol NeoSwapDonorHostProtocol <NSObject>
- (void)donorReady:(NeoSwapMachHandle*)handle metadata:(NSDictionary*)metadata
            reply:(void (^)(BOOL accepted))reply;
- (void)donorUpdate:(NSDictionary*)metadata reply:(void (^)(uint64_t nextMaximumBytes))reply;
- (void)donorFailed:(NSDictionary*)metadata reply:(void (^)(void))reply;
// NSExtension's auxiliary context may ping the host during startup.
- (void)___nsx_pingHost:(void (^)(void))reply;
@end

NSXPCInterface* NeoSwapDonorHostInterface(void);
uint64_t NeoSwapDonorPattern(NSString* nonce, uint64_t generation, BOOL host);
uint64_t NeoSwapDonorChunkPattern(NSString* nonce, uint64_t generation,
                                uint64_t chunkIndex, BOOL host);

@class NeoSwapDonorSession;
typedef void (^NeoSwapDonorObserver)(NeoSwapDonorSession* session,
                                    NeoSwapDonorSnapshot snapshot,
                                    NSError* _Nullable error);

// One outstanding extension request owns independently accounted VM chunks.
// The caller must retain the session while any pool allocation uses this donor.
@interface NeoSwapDonorSession : NSObject
- (instancetype)initWithHelperIdentifier:(NSString*)identifier
                           requestedBytes:(uint64_t)bytes
                               generation:(uint64_t)generation
                                  timeout:(NSTimeInterval)timeout
                                 observer:(NeoSwapDonorObserver)observer;
- (void)start;
- (BOOL)setInitialChunkMaximumBytes:(uint64_t)bytes;
- (void)close;
- (NeoSwapDonorSnapshot)snapshot;
- (NSDictionary*)diagnostics;
// Returns an owned send right only after the bidirectional shared-page proof.
// Caller releases it with mach_port_deallocate after its own retaining map.
- (mach_port_t)copyMemoryEntry;
// Chunks are published only after their own page round trip and incremental
// kernel ledger proof. The index starts at zero within this PID/generation.
- (mach_port_t)copyMemoryEntryForChunk:(uint64_t)index;
- (uint64_t)chunkCapacityBytes:(uint64_t)index;
// Called only after the host pool retained the verified chunk. Growth is driven
// by one global host scheduler, never automatically by the eight helpers.
- (BOOL)acknowledgeVerifiedChunk:(uint64_t)index;
- (BOOL)requestNextChunkWithMaximumBytes:(uint64_t)bytes;
@end

#if defined(NEOSWAP_DONATION_PROBE)
// The macOS XPC service probe checks the same wrapper, session validation and
// shared-page proof. It does not validate the iPhone NSExtension launch route.
@protocol NeoSwapDonorProbeProtocol <NSObject>
- (void)beginProbe:(NSDictionary*)metadata;
@end
@interface NeoSwapDonorSession (MacOSProbe)
- (void)startWithServiceNameForProbe:(NSString*)serviceName;
@end
#endif

NS_ASSUME_NONNULL_END
