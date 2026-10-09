#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "LibretroSkin.h"
#import "LibretroSkinLayout.h"

@class LibretroInputState;
@class LibretroSkinRenderer;
@class LibretroTouchOverlay;

NS_ASSUME_NONNULL_BEGIN

/// What the game view needs to lay out the current skin. Provided by the
/// session; called on the main thread at every layout (rotation, size or
/// setting change).
@protocol LibretroGameViewLayoutSource <NSObject>
/// Representation to show in the view of `size` points for an orientation;
/// the session resolves the selected skin (game, console, default) and falls
/// back to the default skin when the selected one lacks the orientation.
- (LibretroSkinRepresentation *)representationForOrientation:(LibretroSkinOrientation)orientation
                                                    viewSize:(LibretroSize)size
                                                  safeInsets:(LibretroInsets)insets
                                                        iPad:(BOOL)iPad;
/// User layout overrides for the shown representation.
- (nullable NSDictionary<NSString *, NSDictionary *> *)layoutOverridesForRepresentation:
    (LibretroSkinRepresentation *)representation;
/// Applies the layout to the presenter (screens) and the overlay (remaps).
- (void)gameViewDidLayout:(LibretroSkinLayoutResult *)layout
           representation:(LibretroSkinRepresentation *)representation
              drawableSize:(CGSize)drawableSize
                    points:(CGSize)pointSize;
@end

/// Full-screen surface of an embedded libretro session: the CAMetalLayer for
/// the picture, the skin renderer, the touch overlay, a menu button and
/// short status messages. Supports portrait and landscape (see
/// LibretroOrientation).
@interface LibretroGameViewController : UIViewController

- (instancetype)initWithInput:(LibretroInputState *)input cacheDirectory:(NSString *)cacheDirectory;

@property(nonatomic, readonly) CAMetalLayer *metalLayer;
@property(nonatomic, readonly) LibretroSkinRenderer *skinRenderer;
@property(nonatomic, readonly) LibretroTouchOverlay *overlay;
@property(nonatomic, weak, nullable) id<LibretroGameViewLayoutSource> layoutSource;
@property(nonatomic, copy, nullable) void (^menuHandler)(void);
@property(nonatomic, copy, nullable) void (^layoutHandler)(CGSize drawableSize);
@property(nonatomic, copy, nullable) void (^activeHandler)(BOOL active);
/// Normalized touch-screen mappings of the last frame (presenter).
@property(nonatomic, copy, nullable) NSArray<NSValue *> * (^screenMappingsProvider)(void);
@property(nonatomic, assign) BOOL touchControlsEnabled;
@property(nonatomic, assign) CGFloat controlsOpacity;
@property(nonatomic, copy) NSString *menuAccessibilityLabel;
/// Orientations allowed while the game is shown.
@property(nonatomic, assign) UIInterfaceOrientationMask allowedOrientations;

/// Re-runs the skin layout now (setting changed in the menu).
- (void)setNeedsSkinLayout;
@property(nonatomic, readonly) LibretroSkinOrientation currentOrientation;

/// Controls editing ("Commandes › Modifier la disposition"): shows a small
/// toolbar with Done / Reset defaults (translated titles) above the game.
- (void)beginEditingControlsWithDoneTitle:(NSString *)doneTitle
                               resetTitle:(NSString *)resetTitle
                                     hint:(NSString *)hint
                                 finished:(void (^)(void))finished
                                    reset:(void (^)(void))reset;

- (void)showStatus:(NSString *)message;
- (void)setLoading:(BOOL)loading;
- (void)stopInputPolling;

@end

NS_ASSUME_NONNULL_END
