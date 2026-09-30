#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

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
