#import <Flutter/Flutter.h>

// CS_DEBUGGED alone is not proof that Universal JIT is still attached.
BOOL RPCS3JitHasActiveCoreHandshake(void);

@interface Rpcs3JitBridgePlugin : NSObject <FlutterPlugin>
@end
