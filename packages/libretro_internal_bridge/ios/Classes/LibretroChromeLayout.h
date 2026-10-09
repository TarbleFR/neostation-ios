#import <Foundation/Foundation.h>

#import "LibretroFrontendStore.h"
#import "LibretroGeometry.h"
#import "LibretroSkinLayout.h"

NS_ASSUME_NONNULL_BEGIN

/// Size of NeoStation's menu button in the game view (points).
FOUNDATION_EXPORT const LibretroSize LibretroMenuButtonSize;  // 44 x 40
/// Distance kept between the menu button and what it avoids (points).
FOUNDATION_EXPORT const double LibretroMenuButtonClearance;  // 6

/// The game view's own controls ("chrome") over a laid-out skin: where the
/// menu button goes, and what the controls editor starts from. Portable
/// rules shared by LibretroGameViewController, LibretroSession and the macOS
/// host test.
@interface LibretroChromeLayout : NSObject

/// Preferred frame of the menu button, used whenever it is free: top-right
/// corner of the safe area in portrait (game area of the default skins), top
/// centre of the view in landscape.
+ (LibretroRect)preferredMenuButtonFrameForViewSize:(LibretroSize)viewSize safeInsets:(LibretroInsets)safeInsets;

/// Frame of the menu button over `layout` in a view of `viewSize` points.
/// The button is a view above the touch overlay and takes every touch in its
/// frame, so it never covers a touch screen (laid-out screen with
/// `touchScreen`, or touch-screen item): a tap there must reach
/// RETRO_DEVICE_POINTER. When `controlsVisible`, it does not cover any
/// control's hit frame either. Both are kept LibretroMenuButtonClearance
/// away. Rules:
/// - the preferred frame (above) when it is free;
/// - else the free frame closest to it inside the safe area (10 points from
///   the sides, 6 from the top and the bottom), a vertical move counting
///   three times a horizontal one so the button stays near the top; ties
///   go to the higher, then to the more right-hand frame;
/// - when no frame avoids the controls, the closest one that avoids the
///   touch screens; the preferred frame when nothing is free.
/// `layout` nil gives the preferred frame.
+ (LibretroRect)menuButtonFrameForLayout:(nullable LibretroSkinLayoutResult *)layout
                                viewSize:(LibretroSize)viewSize
                              safeInsets:(LibretroInsets)safeInsets
                         controlsVisible:(BOOL)controlsVisible;

/// "Commandes › Déplacer et redimensionner": the overrides the editor starts
/// from, and comes back to after "Reset", for `layoutKey`
/// (controls.layout.<skin>.<orientation>), as the menu pages edit
/// dictionaries: at game scope (`scopeGame` set) the value in effect for
/// that game (its own, else the console's); at console scope the console's
/// own value only, never a game's, so saving at console scope keeps the
/// console's entries and copies nothing from the game on screen. Only
/// {item identifier (string): override (dictionary)} entries are returned.
+ (NSDictionary<NSString *, NSDictionary *> *)controlsEditorOverridesForKey:(NSString *)layoutKey
                                                                      store:(LibretroFrontendStore *)store
                                                                    console:(NSString *)console
                                                                  scopeGame:(nullable NSString *)scopeGame;

/// YES when `game` has its own value for `layoutKey`: that layout keeps
/// applying to the game whatever is saved for the console.
+ (BOOL)game:(nullable NSString *)game
    hasOwnLayoutForKey:(NSString *)layoutKey
                 store:(LibretroFrontendStore *)store
               console:(NSString *)console;

@end

NS_ASSUME_NONNULL_END
