// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>
#include <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

// Guest Page Relay's named-object strategy, integrated through an isolated
// auxiliary connection. Unlike v1 donor handles these entries are ledger-tagged
// and may be 512 MiB. A send right is transported, never its numeric port name.
@interface NeoSwapPageRelayHandle : NSObject <NSSecureCoding>
@property(nonatomic, readonly) mach_port_t memoryEntry;
@property(nonatomic, readonly) uint64_t capacityBytes;
- (nullable instancetype)initWithMemoryEntry:(mach_port_t)entry capacityBytes:(uint64_t)bytes;
+ (BOOL)isTransportAvailable;
@end

@protocol NeoSwapPageRelayHostProtocol <NSObject>
- (void)relayReady:(NeoSwapPageRelayHandle*)handle metadata:(NSDictionary*)metadata
             reply:(void (^)(BOOL retained))reply;
- (void)relayFinished:(NSDictionary*)metadata reply:(void (^)(BOOL mayExit))reply;
- (void)relayFailed:(NSDictionary*)metadata reply:(void (^)(void))reply;
- (void)___nsx_pingHost:(void (^)(void))reply;
@end
NSXPCInterface* NeoSwapPageRelayHostInterface(void);

typedef void (^NeoSwapPageRelayCompletion)(NSArray<NeoSwapPageRelayHandle*>* handles,
    int32_t creatorPID, uint64_t generation, NSError* _Nullable error);

// One preparation has one nonce, one extension request and one completion.
// Capacity is published only after a kernel process-exit event for the exact
// authenticated creator PID. It does NOT imply touched or resident RAM.
// Retain the session until completion/cancellation; retain returned handles
// until the backend has copied their send rights. Retry uses a new session.
@interface NeoSwapPageRelaySession : NSObject
- (instancetype)initWithHelperIdentifier:(NSString*)identifier
                          requestedBytes:(uint64_t)bytes generation:(uint64_t)generation
                                 timeout:(NSTimeInterval)timeout
                              completion:(NeoSwapPageRelayCompletion)completion;
- (void)start;
- (void)cancel;
- (NSDictionary*)diagnostics;
@end

#if defined(NEOSWAP_RELAY_PROBE)
@protocol NeoSwapPageRelayProbeProtocol <NSObject>
- (void)beginRelayProbe:(NSDictionary*)metadata;
@end
@interface NeoSwapPageRelaySession (MacOSProbe)
- (void)startWithServiceNameForProbe:(NSString*)serviceName;
@end
#endif
NS_ASSUME_NONNULL_END
