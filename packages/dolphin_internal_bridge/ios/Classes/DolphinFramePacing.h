// SPDX-License-Identifier: GPL-3.0-or-later
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString* DOLPacingText(NSString* key,NSString* locale);
FOUNDATION_EXPORT NSInteger DOLFrameProfile(void);
FOUNDATION_EXPORT NSInteger DOLRequestedRefresh(NSInteger requested,NSInteger maximum,BOOL lowPower,NSInteger thermal);
@interface DolphinFramePacing : NSObject
@property(nonatomic,copy) NSString* locale;
@property(nonatomic,assign) NSInteger activeProfile;
@property(nonatomic,copy) NSString* gameId;
@property(nonatomic,readonly) BOOL traceEnabled;
@property(nonatomic,readonly) NSDictionary* summary;
@property(nonatomic,readonly) NSArray<NSDictionary*>* samples;
- (void)startWithView:(UIView*)view;
- (void)stop;
- (void)refreshPreference;
- (void)appendPerformance:(NSDictionary*)sample inputMs:(double)inputMs refreshed:(BOOL)refreshed;
- (UIViewController*)settingsController;
@end
NS_ASSUME_NONNULL_END
