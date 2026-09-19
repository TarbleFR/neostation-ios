#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSData* _Nullable DOLSerializeMenuRequest(id _Nullable request);
// Emulator login tokens are separate from NeoStation's dashboard Web API key.
@interface DolphinRetroAchievementsAccount : UIViewController <NSURLSessionTaskDelegate>
+ (nullable NSDictionary<NSString*, NSString*>*)credentials;
+ (void)beginSession;
+ (BOOL)hasPendingChanges;
+ (nullable NSURLRequest*)loginRequestForUsername:(NSString*)username password:(NSString*)password;
+ (nullable NSDictionary<NSString*, NSString*>*)credentialsFromResponse:(NSData*)data;
- (instancetype)initWithLabels:(NSDictionary<NSString*, NSString*>*)labels;
@end
NS_ASSUME_NONNULL_END
