#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Foundation configures the auxiliary connection before calling the principal
// request handler. Both interfaces must exist at that point; assigning only the
// remote interface from beginRequestWithExtensionContext: is too late.
@protocol NeoSwapDonorVendorProtocol <NSObject>
@end

@interface NeoSwapDonorContext : NSExtensionContext <NeoSwapDonorVendorProtocol>
+ (NSXPCInterface*)_extensionAuxiliaryHostProtocol;
+ (NSXPCInterface*)_extensionAuxiliaryVendorProtocol;
@end

// Principal class of the dedicated memory donor appex. It performs no JIT work.
@interface NeoSwapDonorRequestHandler : NSObject <NSExtensionRequestHandling>
@end

#if defined(NEOSWAP_DONATION_PROBE)
@interface NeoSwapDonorRequestHandler (MacOSProbe)
- (void)beginProbeWithConnection:(NSXPCConnection*)connection
                       metadata:(NSDictionary*)metadata;
@end
#endif

NS_ASSUME_NONNULL_END
