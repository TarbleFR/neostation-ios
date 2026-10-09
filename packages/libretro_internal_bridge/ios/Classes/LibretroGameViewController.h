#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

@class LibretroInputState;
@class LibretroTouchOverlay;

NS_ASSUME_NONNULL_BEGIN

/// Full-screen surface of an embedded libretro session: a CAMetalLayer for
/// the picture, the touch overlay, a menu button and short status messages.
@interface LibretroGameViewController : UIViewController

- (instancetype)initWithProfile:(NSString *)profile input:(LibretroInputState *)input;

@property(nonatomic, readonly) CAMetalLayer *metalLayer;
@property(nonatomic, readonly) LibretroTouchOverlay *overlay;
@property(nonatomic, copy, nullable) void (^menuHandler)(void);
@property(nonatomic, copy, nullable) void (^layoutHandler)(CGSize drawableSize);
@property(nonatomic, copy, nullable) void (^activeHandler)(BOOL active);
@property(nonatomic, copy, nullable) CGRect (^videoRectProvider)(void);
@property(nonatomic, assign) BOOL touchControlsEnabled;
@property(nonatomic, copy) NSString *menuAccessibilityLabel;

- (void)showStatus:(NSString *)message;
- (void)setLoading:(BOOL)loading;
- (void)stopInputPolling;

@end

NS_ASSUME_NONNULL_END
