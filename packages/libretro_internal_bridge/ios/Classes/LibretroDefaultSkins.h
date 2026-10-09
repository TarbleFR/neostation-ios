#import <Foundation/Foundation.h>

#import "LibretroSkin.h"

NS_ASSUME_NONNULL_BEGIN

/// Screen arrangements of the DS and 3DS default skins (the core always
/// renders both screens stacked; NeoStation crops and places them).
FOUNDATION_EXPORT NSString *const LibretroArrangementStacked;     // "stacked": top above bottom
FOUNDATION_EXPORT NSString *const LibretroArrangementSideBySide;  // "sideBySide"
FOUNDATION_EXPORT NSString *const LibretroArrangementLargeTop;    // "largeTop": big top, small bottom
FOUNDATION_EXPORT NSString *const LibretroArrangementTopOnly;     // "topOnly"
FOUNDATION_EXPORT NSString *const LibretroArrangementBottomOnly;  // "bottomOnly"

/// NeoStation's built-in skin of every console, inspired by its original
/// controls, generated for the exact view size so it fits every iPhone and
/// iPad in portrait and landscape:
/// - portrait: the game area at the top (below the safe area), the controls
///   below it on an opaque panel in the console's colour;
/// - landscape: the game area over the whole safe area, translucent
///   controls on both sides.
/// Items have semantic identifiers ("dpad", "a", "b", "start", "l",
/// "leftStick", "touchScreen"...) and are all movable except the touch
/// screen. DS/3DS default skins also hold a "touchScreen" item exactly over
/// the bottom screen and no other item intersects it, in every arrangement
/// and orientation. Every item has an accessibility label key: the
/// LibretroInputMap label key, or the glyph itself.
@interface LibretroDefaultSkins : NSObject

/// The 17 console ids with a default skin (same list as LibretroInputMap).
+ (NSArray<NSString *> *)consoles;

/// YES for "nds" and "3ds".
+ (BOOL)isDualScreenConsole:(NSString *)console;

/// Arrangements offered for a dual-screen console (empty otherwise):
/// portrait: stacked, largeTop, topOnly, bottomOnly;
/// landscape: sideBySide, largeTop, stacked, topOnly, bottomOnly.
+ (NSArray<NSString *> *)arrangementsForConsole:(NSString *)console orientation:(LibretroSkinOrientation)orientation;
+ (NSString *)defaultArrangementForConsole:(NSString *)console orientation:(LibretroSkinOrientation)orientation;

/// The default skin descriptor (identifier "default", name filled by the
/// caller from the translations, consoles = @[console], no representation:
/// use the method below).
+ (LibretroSkin *)skinForConsole:(NSString *)console;

/// Representation generated for a view: mappingSize = `viewSize`, items in
/// view points, `generated` = YES. `regions` gives the normalized "top" and
/// "bottom" regions of dual-screen consoles (see LibretroSkin). `swapped`
/// exchanges the places of the two screens (the touch screen keeps
/// following the bottom screen).
+ (LibretroSkinRepresentation *)representationForConsole:(NSString *)console
                                             orientation:(LibretroSkinOrientation)orientation
                                                viewSize:(LibretroSize)viewSize
                                              safeInsets:(LibretroInsets)safeInsets
                                                    iPad:(BOOL)iPad
                                             arrangement:(nullable NSString *)arrangement
                                                 swapped:(BOOL)swapped
                                                 regions:(nullable NSDictionary<NSString *, NSArray<NSNumber *> *> *)regions;

@end

NS_ASSUME_NONNULL_END
