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
/// rotation, a format change or another arrangement of the screens. On the
/// drawn touch screen a control answers only inside its visible frame, never
/// through its extended edges.
@interface LibretroTouchOverlay : UIView

- (instancetype)initWithInput:(LibretroInputState *)input;

/// Main thread, after every layout. `touchRemap` {itemId: [logical inputs]}.
- (void)applyLayout:(nullable LibretroSkinLayoutResult *)layout
           inputMap:(LibretroInputMap *)inputMap
         touchRemap:(nullable NSDictionary<NSString *, NSArray<NSString *> *> *)touchRemap;

/// Touch-screen mappings in overlay points (LibretroScreenMapping in
/// NSValue), refreshed by the game view from the presenter every frame.
/// When they change (or a new layout moves the touch-screen containers), a
/// finger held on the touch screen keeps its mapping while that screen is
/// still drawn at the same place, follows the touch screen now under it, or
/// is released when there is none (screens swapped under a held stylus).
@property(nonatomic, copy) NSArray<NSValue *> *touchScreenMappings;

/// Physical controller connected or touch controls switched off: buttons,
/// D-pads and sticks are ignored, the touch screen keeps working.
@property(nonatomic, assign) BOOL controlsDisabled;

/// Frontend actions from skin items (menu, quick save/load, fast forward,
/// swap screens). `pressed` is NO on release (used by "fastForward").
@property(nonatomic, copy, nullable) void (^actionHandler)(LibretroFrontendAction action, BOOL pressed);
/// Items currently pressed, for LibretroSkinRenderer highlights.
@property(nonatomic, copy, nullable) void (^pressedItemsChanged)(NSSet<NSString *> *itemIdentifiers);
/// Deflection of every thumbstick held by a finger, reported when it
/// changes: {itemId: NSValue of a CGPoint, x and y in -1...1, y positive
/// downward}; a released stick is absent (centred). For
/// -[LibretroSkinRenderer setStickVectors:], so the knob follows the finger.
@property(nonatomic, copy, nullable) void (^stickVectorsChanged)(NSDictionary<NSString *, NSValue *> *vectors);

/// Layout editing: one finger drags the touched movable item, two fingers
/// pinch it. Changes are reported as cumulative overrides relative to the
/// skin (dx, dy in fractions of the overlay size; scale clamped 0.5-2.0).
/// A proposal that cannot be placed (inside the view, off the touch screen)
/// is ignored: the item keeps its last valid place. Starting or ending
/// editing clears the selection.
@property(nonatomic, assign) BOOL editing;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *editOverrides;
@property(nonatomic, copy, nullable) void (^editChanged)
    (NSString *itemIdentifier, NSDictionary<NSString *, NSNumber *> *override);
@property(nonatomic, copy, nullable) void (^editSelectionChanged)(NSString *_Nullable itemIdentifier);

/// Forgets the selected item and the gesture in progress (Reset of the
/// editing toolbar, end of editing), so a later two-finger pinch never
/// resizes an item that is not shown as selected. Does not call
/// editSelectionChanged (the caller clears its own selection).
- (void)clearEditSelection;

- (void)releaseAllTouches;

@end

NS_ASSUME_NONNULL_END
