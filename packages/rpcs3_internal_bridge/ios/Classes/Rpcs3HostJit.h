#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Enables JIT for NeoStation's own process through the embedded RPCS3 helper.
/// This bridge is owned exclusively by the in-process RPCS3 integration.
NSDictionary<NSString*, id>* RPCS3PrepareHostJit(NSString* pairingFilePath);

NS_ASSUME_NONNULL_END
