#import <Foundation/Foundation.h>

#import "LibretroCoreHost.h"
#import "LibretroInputMap.h"

NS_ASSUME_NONNULL_BEGIN

/// Input shared between UIKit (touch overlay, controller polling on the main
/// thread) and the emulation thread, which copies it once per input poll.
@interface LibretroInputState : NSObject

/// Touch controls (already translated to RetroPad) always drive port 0.
- (void)setTouchInput:(LibretroCoreInput)input;
- (void)setPointerX:(int16_t)x y:(int16_t)y pressed:(BOOL)pressed;

/// Console map and user gamepad remap {element: logical input} used by
/// `pollControllers` (main thread). Defaults to the "nes" map.
- (void)setInputMap:(LibretroInputMap *)inputMap gamepadRemap:(nullable NSDictionary<NSString *, NSString *> *)remap;

/// Reads every connected GCController (main thread). Returns YES when a
/// controller asked for the session menu (Home, Options + Menu, or a button
/// remapped to "menu"). Other remapped frontend actions are reported
/// through `actionHandler` on press and release.
- (BOOL)pollControllers;
@property(nonatomic, readonly) BOOL hasPhysicalController;
@property(nonatomic, copy, nullable) void (^actionHandler)(LibretroFrontendAction action, BOOL pressed);

/// Physical element currently pressed on any controller, for "press the
/// button to assign" in the menu; nil when none.
@property(nonatomic, readonly, nullable) NSString *pressedGamepadElement;

/// Copies the combined state for the core (emulation thread).
- (void)snapshot:(LibretroInputSnapshot *)snapshot;

/// Releases every button, for instance before the session menu opens.
- (void)reset;

@end

NS_ASSUME_NONNULL_END
