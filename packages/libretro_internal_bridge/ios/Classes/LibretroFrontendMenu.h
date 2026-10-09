#import <UIKit/UIKit.h>

#import "LibretroFrontendStore.h"
#import "LibretroInputMap.h"
#import "LibretroSessionMenu.h"
#import "LibretroSkin.h"

NS_ASSUME_NONNULL_BEGIN

/// What the frontend pages of the in-game menu need from the running
/// session. Implemented by LibretroSession. Main thread only.
@protocol LibretroFrontendMenuHost <NSObject>
/// Translated label (uiText); returns the key itself when missing.
- (NSString *)text:(NSString *)key;
@property(nonatomic, readonly, copy) NSString *uiLocale;
@property(nonatomic, readonly, copy) NSString *console;
@property(nonatomic, readonly, copy) NSString *consoleName;
@property(nonatomic, readonly, copy) NSString *gameKey;
@property(nonatomic, readonly) LibretroFrontendStore *frontendStore;
@property(nonatomic, readonly) LibretroInputMap *inputMap;
/// Default skin first, then imported skins compatible with the console
/// (parsed once per menu opening).
@property(nonatomic, readonly, copy) NSArray<LibretroSkin *> *availableSkins;
/// Representation used for a skin's preview in an orientation at the
/// current view size (default skins are generated for it); nil when the
/// skin lacks that orientation.
- (nullable LibretroSkinRepresentation *)previewRepresentationForSkin:(LibretroSkin *)skin
                                                         orientation:(LibretroSkinOrientation)orientation;
/// Renders a preview off the main thread (LibretroSkinRenderer).
- (void)renderPreviewForRepresentation:(LibretroSkinRepresentation *)representation
                                  size:(CGSize)size
                            completion:(void (^)(UIImage *_Nullable image))completion;
@property(nonatomic, readonly) LibretroSkinOrientation currentOrientation;
/// Skin and representation on screen now.
@property(nonatomic, readonly) LibretroSkin *currentSkin;
@property(nonatomic, readonly) LibretroSkinRepresentation *currentRepresentation;
/// Display aspect of the whole core picture.
@property(nonatomic, readonly) double coreAspectRatio;
/// NO when Vulkan frames cannot reach Metal (legacy presentation).
@property(nonatomic, readonly) BOOL screensAndShadersAvailable;
@property(nonatomic, readonly) BOOL physicalControllerConnected;
/// Re-resolves every frontend setting from the store (game > console >
/// default) and applies it live: layout, screens, format, input remaps,
/// opacity; then redraws the last frame (coalesced). Shader settings are
/// applied by applyShaderPreset... below.
- (void)frontendSettingsDidChange;
/// Compiles and activates a preset on the emulation thread (nil = none).
/// `completion` (main queue) gets NO when compilation failed: the standard
/// picture is then active and the caller must not save the preset.
- (void)applyShaderPreset:(nullable NSString *)presetIdentifier
               parameters:(nullable NSDictionary<NSString *, NSNumber *> *)parameters
               completion:(void (^)(BOOL success))completion;
/// Live parameter change while a slider moves (not saved, redraw coalesced).
- (void)previewShaderParameter:(NSString *)identifier value:(float)value;
/// Median GPU time of the active preset measured on the last frame
/// (completion on the main queue, milliseconds, 0 when unknown).
- (void)measureShaderWithCompletion:(void (^)(double milliseconds))completion;
/// Closes the menu and starts "Déplacer et redimensionner" for the current
/// skin and orientation; the overrides are saved for `gameKey` (game
/// scope) or nil (console scope) when the user taps Done.
- (void)beginControlsEditingForGame:(nullable NSString *)gameKey;
- (void)showStatus:(NSString *)message;
@end

/// Builds the "Skins", "Format d'écran", "Disposition des écrans" (DS / 3DS),
/// "Shaders" and "Commandes" entries of the in-game menu and their pages.
/// Every page starts with a "Save for" section (this console / this game
/// only), shows where each value comes from (valueFromGame /
/// valueFromConsole / valueDefault), offers "Restore defaults" for the
/// chosen scope, and writes LibretroFrontendStore keys (see its header)
/// before asking the host to apply them. Pages whose effect is visible on
/// the game set `previewsGame`.
@interface LibretroFrontendMenu : NSObject

- (instancetype)initWithHost:(id<LibretroFrontendMenuHost>)host;

/// Rows to insert in the root menu's "display" section, in this order:
/// Skins, Format d'écran, Disposition des écrans (DS / 3DS only), Shaders,
/// Commandes. Each row has a detail summarising the current value and
/// pushes its page.
- (NSArray<LibretroMenuRow *> *)rootRows;

@end

NS_ASSUME_NONNULL_END
