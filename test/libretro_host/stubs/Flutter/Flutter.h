// Declarations of the Flutter plugin API used by LibretroInternalBridgePlugin,
// for the iPhone syntax check only. The real header comes from Flutter.
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^FlutterResult)(id _Nullable result);
FOUNDATION_EXPORT NSObject *const FlutterMethodNotImplemented;
@protocol FlutterBinaryMessenger <NSObject>
@end
@class FlutterMethodChannel;
@interface FlutterMethodCall : NSObject
@property(nonatomic, copy) NSString *method;
@property(nonatomic, strong, nullable) id arguments;
@end
@protocol FlutterPluginRegistrar <NSObject>
@property(nonatomic, readonly) NSObject<FlutterBinaryMessenger> *messenger;
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel *)channel;
@end
@protocol FlutterPlugin <NSObject>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar;
@optional
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result;
@end
@interface FlutterMethodChannel : NSObject
+ (instancetype)methodChannelWithName:(NSString *)name binaryMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
- (void)invokeMethod:(NSString *)method arguments:(id _Nullable)arguments;
@end
NS_ASSUME_NONNULL_END
