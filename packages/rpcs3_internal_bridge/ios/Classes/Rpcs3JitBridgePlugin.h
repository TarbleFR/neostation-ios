#import <Flutter/Flutter.h>

// CS_DEBUGGED alone is not proof that Universal JIT is still attached.
BOOL RPCS3JitHasActiveCoreHandshake(void);
// Executes an authenticated BRK/nonce/resume round trip on the calling thread.
// The Core loader calls this at the last boundary immediately before dlopen.
BOOL RPCS3JitConfirmCoreLoadHandoff(void);

@interface Rpcs3JitBridgePlugin : NSObject <FlutterPlugin>
@end
