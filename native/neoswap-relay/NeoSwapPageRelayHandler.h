// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@protocol NeoSwapPageRelayVendorProtocol <NSObject>
@end
@interface NeoSwapPageRelayContext : NSExtensionContext <NeoSwapPageRelayVendorProtocol>
+ (NSXPCInterface*)_extensionAuxiliaryHostProtocol;
+ (NSXPCInterface*)_extensionAuxiliaryVendorProtocol;
@end
@interface NeoSwapPageRelayHandler : NSObject <NSExtensionRequestHandling>
@end
#if defined(NEOSWAP_RELAY_PROBE)
@interface NeoSwapPageRelayHandler (MacOSProbe)
- (void)beginProbeWithConnection:(NSXPCConnection*)connection metadata:(NSDictionary*)metadata;
@end
#endif
NS_ASSUME_NONNULL_END
