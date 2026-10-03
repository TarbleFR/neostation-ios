// Minimal Flutter channel harness only. UIKit is the real Apple SDK; this
// binary checks native host behavior independently of Flutter engine startup.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^FlutterResult)(id _Nullable result);
FOUNDATION_EXPORT NSObject* const FlutterMethodNotImplemented;
@protocol FlutterBinaryMessenger <NSObject>
@end
@class FlutterMethodChannel;
@interface FlutterMethodCall : NSObject
@property(nonatomic, copy) NSString* method;
@property(nonatomic, strong) id _Nullable arguments;
@end
@protocol FlutterPluginRegistrar <NSObject>
@property(nonatomic, readonly) NSObject<FlutterBinaryMessenger>* messenger;
@property(nonatomic, readonly) UIViewController* viewController;
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel*)channel;
@end
@protocol FlutterPlugin <NSObject>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result;
@end
@interface FlutterMethodChannel : NSObject
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger;
- (void)invokeMethod:(NSString*)method arguments:(id _Nullable)arguments;
@end
NS_ASSUME_NONNULL_END
