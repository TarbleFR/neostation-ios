#import <Foundation/Foundation.h>

#import "LibretroCoreHost.h"

NS_ASSUME_NONNULL_BEGIN

/// Input shared between UIKit (touch overlay, controller polling on the main
/// thread) and the emulation thread, which copies it once per input poll.
@interface LibretroInputState : NSObject

/// Overlay buttons and sticks always drive port 0.
- (void)setTouchButtons:(uint16_t)buttons;
- (void)setTouchStick:(unsigned)stick x:(int16_t)x y:(int16_t)y;
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed;

/// Reads every connected GCController (main thread). Returns YES when a
/// controller asked for the session menu (Home, or Options + Menu).
- (BOOL)pollControllers;
@property(nonatomic, readonly) BOOL hasPhysicalController;

/// Copies the combined state for the core (emulation thread).
- (void)snapshot:(LibretroInputSnapshot *)snapshot;

/// Releases every button, for instance before the session menu opens.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
