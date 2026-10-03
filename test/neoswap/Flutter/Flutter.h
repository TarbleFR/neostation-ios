#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
typedef void (^FlutterResult)(id _Nullable result);
FOUNDATION_EXPORT NSObject* const FlutterMethodNotImplemented;
@protocol FlutterBinaryMessenger <NSObject>
@end
@class FlutterMethodChannel;
@interface FlutterError : NSObject
+ (instancetype)errorWithCode:(NSString*)code message:(NSString* _Nullable)message details:(id _Nullable)details;
@end
@interface FlutterMethodCall : NSObject
@property(nonatomic,copy) NSString* method;
@property(nonatomic,strong) id _Nullable arguments;
@end
@protocol FlutterPluginRegistrar <NSObject>
@property(nonatomic,readonly) NSObject<FlutterBinaryMessenger>* messenger;
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel*)channel;
@end
@protocol FlutterPlugin <NSObject>
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar;
- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result;
@end
@interface FlutterMethodChannel : NSObject
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger;
@end
NS_ASSUME_NONNULL_END
