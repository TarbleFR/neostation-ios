#import <Foundation/Foundation.h>

#import "LibretroGeometry.h"
#import "LibretroSkin.h"

NS_ASSUME_NONNULL_BEGIN

/// One item placed in view coordinates (points).
@interface LibretroLaidOutItem : NSObject
@property(nonatomic, strong) LibretroSkinItem *item;
@property(nonatomic, assign) LibretroRect frame;
@property(nonatomic, assign) LibretroRect hitFrame;
@property(nonatomic, assign) LibretroRect assetFrame;
@end

/// One screen container in view coordinates (points). The presenter fits
/// the picture inside `container` with the chosen screen format.
@interface LibretroLaidOutScreen : NSObject
@property(nonatomic, assign) LibretroRect container;
@property(nonatomic, assign) LibretroRect source;
@property(nonatomic, copy) NSString *role;
@property(nonatomic, assign) BOOL touchScreen;
@end

@interface LibretroSkinLayoutResult : NSObject
/// Where the mapping area of the representation sits in the view.
@property(nonatomic, assign) LibretroRect skinRect;
@property(nonatomic, copy) NSArray<LibretroLaidOutItem *> *items;
/// Never empty: a skin without screens gets one "full" screen.
@property(nonatomic, copy) NSArray<LibretroLaidOutScreen *> *screens;
/// Representation's panel (`panelColor` != 0) in view points; empty
/// otherwise.
@property(nonatomic, assign) LibretroRect panelFrame;
@end

/// Pure layout math shared by the game view, the touch overlay, previews
/// and the macOS host test.
@interface LibretroSkinLayout : NSObject

/// Lays out `representation` in a view of `viewSize` points:
/// - generated (default) skins: mapping == view, items and screens as is;
/// - imported skins, Delta rules: in portrait, when no screen has an
///   output frame, the skin is pinned to the bottom at full width (height =
///   width * mappingH / mappingW) and the single screen fills the area above
///   it; otherwise the mapping is aspect-fitted and centred in the full view
///   (safe areas ignored, as the skin was designed edge to edge), screens
///   with an output frame are scaled into it and screens without one fill
///   the whole view.
/// `overrides` are the user's layout changes {itemId: {"dx": fraction of
/// the view width, "dy": fraction of the view height, "scale": factor
/// 0.5...2.0}} applied to movable items only (frame, hit frame and asset
/// frame move together; scale is around the frame centre).
+ (LibretroSkinLayoutResult *)layoutRepresentation:(LibretroSkinRepresentation *)representation
                                          viewSize:(LibretroSize)viewSize
                                        safeInsets:(LibretroInsets)safeInsets
                                         overrides:(nullable NSDictionary<NSString *, NSDictionary *> *)overrides;

/// Clamps a layout override so the moved / resized item stays inside the
/// view and neither its frame nor its touch area (hit frame) intersects any
/// touch-screen container or touch-screen item (the DS / 3DS touch screen
/// must never be covered by a moved button). An imported skin whose own
/// design already lets the item's touch area reach a touch screen keeps
/// only the frame off it (the hit test then gives the touch screen priority
/// outside the frame). Returns the corrected override {dx, dy, scale}; when
/// no position fits, the original place {0, 0, 1}.
+ (NSDictionary<NSString *, NSNumber *> *)clampOverride:(NSDictionary<NSString *, NSNumber *> *)override
                                                forItem:(LibretroSkinItem *)item
                                         representation:(LibretroSkinRepresentation *)representation
                                               viewSize:(LibretroSize)viewSize
                                             safeInsets:(LibretroInsets)safeInsets;

/// Same clamp for an editing gesture: when no position fits `override`
/// (for example a pinch too large for the room left beside the touch
/// screen), returns `previous` (the last valid override, clamped again) or,
/// when `previous` is nil or no longer fits, the original place {0, 0, 1}.
/// `fitted` (optional) is set to YES only when `override` itself could be
/// placed, so a caller can ignore a proposal that does not fit.
+ (NSDictionary<NSString *, NSNumber *> *)clampOverride:(NSDictionary<NSString *, NSNumber *> *)override
                                               previous:(nullable NSDictionary<NSString *, NSNumber *> *)previous
                                                forItem:(LibretroSkinItem *)item
                                         representation:(LibretroSkinRepresentation *)representation
                                               viewSize:(LibretroSize)viewSize
                                             safeInsets:(LibretroInsets)safeInsets
                                                 fitted:(nullable BOOL *)fitted;

/// Items hit by a point, Delta rules: a thumbstick containing the point
/// wins alone; else an item with the "menu" input is exclusive; else every
/// button / D-pad whose hit frame contains the point; touch-screen items are
/// returned only when nothing else is hit. On a drawn touch screen (the
/// layout's touch-screen containers, or the frame of a touch-screen item),
/// a control is hit only inside its visible frame: its extended edges never
/// take a touch from the touch screen.
+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x y:(double)y inLayout:(LibretroSkinLayoutResult *)layout;

/// Same, with the rectangles where the touch screens are really drawn
/// (`touchAreas`: NSValue of LibretroRect in view points, for example the
/// presenter's touch-screen mappings, which can be smaller than their
/// container); nil uses the layout's touch-screen containers. The frames of
/// touch-screen items always count as touch screen.
+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x
                                           y:(double)y
                                    inLayout:(LibretroSkinLayoutResult *)layout
                                  touchAreas:(nullable NSArray<NSValue *> *)touchAreas;

/// Knob of a thumbstick item for a stick vector (`x`, `y` in -1...1,
/// clamped; y positive downward): centred on the frame for {0, 0}, moved by
/// the vector times half the room between the knob and the frame (a
/// quarter of the frame when the knob is as large as the frame). The knob
/// size is the item's `thumbstickSize` scaled with the laid-out frame, or
/// half the frame without one.
+ (LibretroRect)knobFrameForItem:(LibretroLaidOutItem *)laidOut stickX:(double)x stickY:(double)y;

/// Pointer mapping a held finger keeps after the touch-screen mappings
/// changed (screens swapped or moved, another arrangement): `current`
/// unchanged when it is still published; else the published mapping whose
/// output contains (`x`, `y`). Returns NO when the finger is no longer on
/// any touch screen (the pointer must then be released). `mappings` holds
/// LibretroScreenMapping values (other values are ignored).
+ (BOOL)resolvePointerMapping:(LibretroScreenMapping)current
                         atX:(double)x
                           y:(double)y
                    mappings:(NSArray<NSValue *> *)mappings
                      result:(nullable LibretroScreenMapping *)result;

@end

NS_ASSUME_NONNULL_END
