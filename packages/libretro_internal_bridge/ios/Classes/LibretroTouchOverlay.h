#import <UIKit/UIKit.h>

@class LibretroInputState;

NS_ASSUME_NONNULL_BEGIN

/// On-screen controls drawn over the game, laid out per console family.
///
/// Buttons drive the RetroPad of port 0 with multitouch (a finger can slide
/// across the D-pad or between face buttons). For the DS and 3DS, a touch on
/// the picture outside every control is forwarded as RETRO_DEVICE_POINTER.
@interface LibretroTouchOverlay : UIView

- (instancetype)initWithProfile:(NSString *)profile input:(LibretroInputState *)input;

/// Picture rectangle in the overlay's coordinates, for pointer mapping.
@property(nonatomic, assign) CGRect videoRect;
@property(nonatomic, readonly) BOOL usesPointer;

- (void)releaseAllTouches;

@end

NS_ASSUME_NONNULL_END
