#import <Foundation/Foundation.h>
typedef void (^FlutterResult)(id _Nullable result);
FOUNDATION_EXPORT NSObject* const FlutterMethodNotImplemented;
@protocol FlutterBinaryMessenger <NSObject>
@end
@class FlutterMethodChannel;
@interface FlutterMethodCall : NSObject
@property(nonatomic,copy) NSString* method;
@property(nonatomic,strong) id arguments;
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
