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
/// view and its frame does not intersect any touch-screen container (the
/// DS / 3DS touch screen must never be covered by a moved button). Returns
/// the corrected override {dx, dy, scale}.
+ (NSDictionary<NSString *, NSNumber *> *)clampOverride:(NSDictionary<NSString *, NSNumber *> *)override
                                                forItem:(LibretroSkinItem *)item
                                         representation:(LibretroSkinRepresentation *)representation
                                               viewSize:(LibretroSize)viewSize
                                             safeInsets:(LibretroInsets)safeInsets;

/// Items hit by a point, Delta rules: a thumbstick containing the point
/// wins alone; else an item with the "menu" input is exclusive; else every
/// button / D-pad whose hit frame contains the point; touch-screen items are
/// returned only when nothing else is hit.
+ (NSArray<LibretroLaidOutItem *> *)itemsAtX:(double)x y:(double)y inLayout:(LibretroSkinLayoutResult *)layout;

@end

NS_ASSUME_NONNULL_END
