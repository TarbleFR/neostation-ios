#import "Rpcs3CompositeBridgePlugin.h"
#import "Rpcs3InternalBridgePlugin.h"
#import "Rpcs3JitBridgePlugin.h"

@implementation Rpcs3CompositeBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [Rpcs3InternalBridgePlugin registerWithRegistrar:registrar];
  [Rpcs3JitBridgePlugin registerWithRegistrar:registrar];
}

@end
