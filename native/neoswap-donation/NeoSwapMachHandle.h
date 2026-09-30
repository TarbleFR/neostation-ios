#pragma once

#import <Foundation/Foundation.h>
#include <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

// A copied Mach send right, never a serialized numeric port name. This object
// only supports NSXPCCoder; it cannot be archived to a file or JSON payload.
@interface NeoSwapMachHandle : NSObject <NSSecureCoding>
@property(nonatomic, readonly) mach_port_t memoryEntry;
@property(nonatomic, readonly) uint64_t capacityBytes;
- (nullable instancetype)initWithMemoryEntry:(mach_port_t)entry
                              capacityBytes:(uint64_t)bytes;
+ (BOOL)isTransportAvailable;
@end

NS_ASSUME_NONNULL_END
