#pragma once
#import <Flutter/Flutter.h>
#import <Foundation/Foundation.h>

@interface Armsx2JitBridgePlugin : NSObject <FlutterPlugin>
@end

#ifdef __cplusplus
extern "C" {
#endif
BOOL ARMSX2JitHasActiveCoreHandshake(void);
BOOL ARMSX2JitConfirmCoreLoadHandoff(void);
BOOL ARMSX2JitWaitForDetach(NSTimeInterval timeout, NSString* _Nullable * _Nullable message);
void ARMSX2JitAbortTransaction(void);
#ifdef __cplusplus
}
#endif
