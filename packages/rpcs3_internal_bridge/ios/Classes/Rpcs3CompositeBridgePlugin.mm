#import "Rpcs3CompositeBridgePlugin.h"
#import "Rpcs3DocumentPickerPlugin.h"
#import "Rpcs3InternalBridgePlugin.h"
#import "Rpcs3JitBridgePlugin.h"
#import "Rpcs3RuntimeTuningPlugin.h"

@implementation Rpcs3CompositeBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  [Rpcs3InternalBridgePlugin registerWithRegistrar:registrar];
  [Rpcs3JitBridgePlugin registerWithRegistrar:registrar];
  [Rpcs3RuntimeTuningPlugin registerWithRegistrar:registrar];
  [Rpcs3DocumentPickerPlugin registerWithRegistrar:registrar];
}

@end
