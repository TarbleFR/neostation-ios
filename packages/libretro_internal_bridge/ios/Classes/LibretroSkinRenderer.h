#import <UIKit/UIKit.h>

#import "LibretroSkin.h"
#import "LibretroSkinLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// Draws a skin representation above the game picture: the background image
/// and the items, either their own images (imported skins) or NeoStation's
/// vector style (default skins). One CALayer per item (CAShapeLayer /
/// CATextLayer for vector items); highlight changes run inside
/// [CATransaction setDisableActions:YES]. Never receives touches
/// (userInteractionEnabled = NO); LibretroTouchOverlay sits above it.
///
/// Images (PNG / JPEG decoded with ImageIO downsampling, PDF page 1
/// rasterised with CoreGraphics, one CGPDFDocument per render) are produced
/// on a private serial background queue at the on-screen pixel size, kept in
/// an NSCache with a cost limit and on disk under
/// <cacheDirectory>/SkinCache (key: skin directory, file, pixel size,
/// scale); the previous image stays visible until the new one is ready.
/// Public methods: main thread only.
@interface LibretroSkinRenderer : UIView

- (instancetype)initWithCacheDirectory:(NSString *)cacheDirectory;

/// Replaces the drawn representation. `opacity` applies to the controls of
/// translucent and default skins (background images of opaque skins stay
/// fully opaque). `controlsHidden` hides items but keeps the background and
/// the touch-screen area (physical controller connected).
- (void)showRepresentation:(nullable LibretroSkinRepresentation *)representation
                    layout:(nullable LibretroSkinLayoutResult *)layout
                   opacity:(CGFloat)opacity
            controlsHidden:(BOOL)controlsHidden;

/// Highlights the items currently pressed (by identifier).
- (void)setPressedItems:(NSSet<NSString *> *)itemIdentifiers;

/// Editing mode of "Commandes › Déplacer et redimensionner": dashed
/// outlines around movable items and a highlight on `selectedItem`. During
/// a pinch the item layer is only scaled; it is re-rasterised at the end.
- (void)setEditing:(BOOL)editing selectedItem:(nullable NSString *)itemIdentifier;

/// Removes cached images of one skin directory (deleted or replaced skin).
+ (void)purgeCacheForSkinDirectory:(NSString *)directory cacheDirectory:(NSString *)cacheDirectory;

/// Preview for the skin pickers (in-game menu and Flutter): background,
/// items and grey placeholders for the screens, rendered off the main
/// thread into an image of `size` points at `scale`. `completion` runs on
/// the main queue (nil image on failure).
+ (void)renderPreviewForRepresentation:(LibretroSkinRepresentation *)representation
                                  size:(CGSize)size
                                 scale:(CGFloat)scale
                            safeInsets:(UIEdgeInsets)safeInsets
                        cacheDirectory:(NSString *)cacheDirectory
                            completion:(void (^)(UIImage *_Nullable image))completion;

@end

NS_ASSUME_NONNULL_END
