#import <UIKit/UIKit.h>

#import "LibretroInputMap.h"
#import "LibretroSkinLayout.h"

@class LibretroInputState;

NS_ASSUME_NONNULL_BEGIN

/// Touch layer of a skin, above LibretroSkinRenderer.
///
/// Skin items produce logical inputs (LibretroInputMap names), translated to
/// the RetroPad of port 0 through the console's input map; user touch remaps
/// replace an item's inputs. Delta rules: every item under a finger fires,
/// "menu" is exclusive, a finger can slide across the D-pad or between
/// buttons, sticks stay bound to their finger. A touch inside a touch-screen
/// screen (DS / 3DS bottom screen) that hits no other item becomes
/// RETRO_DEVICE_POINTER through LibretroPointerFromPoint, with the screen's
/// real output rectangle (`touchScreenMappings`), so it stays correct after a
/// rotation, a format change or another arrangement of the screens.
@interface LibretroTouchOverlay : UIView

- (instancetype)initWithInput:(LibretroInputState *)input;

/// Main thread, after every layout. `touchRemap` {itemId: [logical inputs]}.
- (void)applyLayout:(nullable LibretroSkinLayoutResult *)layout
           inputMap:(LibretroInputMap *)inputMap
         touchRemap:(nullable NSDictionary<NSString *, NSArray<NSString *> *> *)touchRemap;

/// Touch-screen mappings in overlay points (LibretroScreenMapping in
/// NSValue), refreshed by the game view from the presenter every frame.
@property(nonatomic, copy) NSArray<NSValue *> *touchScreenMappings;

/// Physical controller connected or touch controls switched off: buttons,
/// D-pads and sticks are ignored, the touch screen keeps working.
@property(nonatomic, assign) BOOL controlsDisabled;

/// Frontend actions from skin items (menu, quick save/load, fast forward,
/// swap screens). `pressed` is NO on release (used by "fastForward").
@property(nonatomic, copy, nullable) void (^actionHandler)(LibretroFrontendAction action, BOOL pressed);
/// Items currently pressed, for LibretroSkinRenderer highlights.
@property(nonatomic, copy, nullable) void (^pressedItemsChanged)(NSSet<NSString *> *itemIdentifiers);

/// Layout editing: one finger drags the touched movable item, two fingers
/// pinch it. Changes are reported as cumulative overrides relative to the
/// skin (dx, dy in fractions of the overlay size; scale clamped 0.5-2.0).
@property(nonatomic, assign) BOOL editing;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *editOverrides;
@property(nonatomic, copy, nullable) void (^editChanged)
    (NSString *itemIdentifier, NSDictionary<NSString *, NSNumber *> *override);
@property(nonatomic, copy, nullable) void (^editSelectionChanged)(NSString *_Nullable itemIdentifier);

- (void)releaseAllTouches;

@end

NS_ASSUME_NONNULL_END
