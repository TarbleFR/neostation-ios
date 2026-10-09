#import <Foundation/Foundation.h>

#import "LibretroGeometry.h"

NS_ASSUME_NONNULL_BEGIN

/// Identifier of the built-in NeoStation skin of every console.
FOUNDATION_EXPORT NSString *const LibretroDefaultSkinIdentifier;  // @"default"

typedef NS_ENUM(NSInteger, LibretroSkinOrientation) {
  LibretroSkinOrientationPortrait = 0,
  LibretroSkinOrientationLandscape = 1,
};
/// "portrait" / "landscape".
FOUNDATION_EXPORT NSString *LibretroSkinOrientationName(LibretroSkinOrientation orientation);

typedef NS_ENUM(NSInteger, LibretroSkinItemKind) {
  LibretroSkinItemKindButton = 0,
  LibretroSkinItemKindDPad,
  LibretroSkinItemKindThumbstick,
  LibretroSkinItemKindTouchScreen,
};

/// Vector style of NeoStation's default skins (imported skins draw images).
typedef NS_ENUM(NSInteger, LibretroSkinItemShape) {
  LibretroSkinItemShapeNone = 0,      // invisible hit area
  LibretroSkinItemShapeCircle,
  LibretroSkinItemShapePill,          // start / select / mode
  LibretroSkinItemShapeRounded,       // shoulder and trigger buttons
  LibretroSkinItemShapeDPad,
  LibretroSkinItemShapeStick,
};

/// One control of a skin representation. Coordinates are in mapping units
/// of the representation.
@interface LibretroSkinItem : NSObject <NSCopying>
/// Stable within its representation: "item0", "item1"... for imported
/// skins (index in info.json), semantic ids ("a", "dpad", "leftStick",
/// "touchScreen") for default skins. Used by user remaps and layouts.
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, assign) LibretroSkinItemKind kind;
@property(nonatomic, assign) LibretroRect frame;
/// Touch area: frame grown by the extended edges.
@property(nonatomic, assign) LibretroRect hitFrame;
/// Canonical logical inputs (see LibretroInputMap). Buttons: every input is
/// pressed together. D-pad and thumbstick: exactly four entries, the
/// targets of up, down, left, right. Touch screen: @[@"touchScreen"].
@property(nonatomic, copy) NSArray<NSString *> *inputs;
/// Raw input names of the skin that NeoStation does not support (kept for
/// the import report; the item stays drawn but inert for them).
@property(nonatomic, copy) NSArray<NSString *> *unsupportedInputs;
/// Imported skins: absolute path of the item's own image (PNG or PDF) and
/// where it is drawn (centred on the frame).
@property(nonatomic, copy, nullable) NSString *assetPath;
@property(nonatomic, assign) LibretroRect assetFrame;
/// Thumbstick knob image and size (mapping units) for imported skins.
@property(nonatomic, copy, nullable) NSString *thumbstickAssetPath;
@property(nonatomic, assign) LibretroSize thumbstickSize;
/// Default skins: vector rendering.
@property(nonatomic, assign) LibretroSkinItemShape shape;
@property(nonatomic, copy, nullable) NSString *label;  // product glyph, never translated
@property(nonatomic, assign) uint32_t fillColor;       // 0xAARRGGBB
@property(nonatomic, assign) uint32_t labelColor;      // 0xAARRGGBB
/// The user may move, resize and remap this item ("Commandes").
@property(nonatomic, assign) BOOL movable;
@end

/// Where a part of the core image is drawn.
@interface LibretroSkinScreen : NSObject <NSCopying>
/// Destination in mapping units; `hasOutputFrame` NO means "fit
/// automatically in the game area" (Delta behaviour).
@property(nonatomic, assign) LibretroRect outputFrame;
@property(nonatomic, assign) BOOL hasOutputFrame;
/// Delta `placement: "app"`: `outputFrame` is normalized (0-1) in the game
/// area instead of mapping units (LibretroSkinLayout honours it).
@property(nonatomic, assign) BOOL appPlacement;
/// Normalized part of the core image (top-left origin): {0,0,1,1} for the
/// whole picture; for DS/3DS the region of the "top" or "bottom" screen.
@property(nonatomic, assign) LibretroRect source;
/// "full", "top" or "bottom".
@property(nonatomic, copy) NSString *role;
/// Touches inside this screen go to RETRO_DEVICE_POINTER.
@property(nonatomic, assign) BOOL touchScreen;
@end

/// One device / display type / orientation of a skin.
@interface LibretroSkinRepresentation : NSObject
@property(nonatomic, assign) LibretroSkinOrientation orientation;
@property(nonatomic, copy) NSString *device;       // "iphone" or "ipad"
@property(nonatomic, copy) NSString *displayType;  // "standard" or "edgeToEdge"
@property(nonatomic, assign) LibretroSize mappingSize;
/// Background image (absolute path, PNG/JPEG/PDF detected by content).
@property(nonatomic, copy, nullable) NSString *backgroundPath;
@property(nonatomic, copy) NSArray<LibretroSkinItem *> *items;
@property(nonatomic, copy) NSArray<LibretroSkinScreen *> *screens;
/// Delta "translucent": controls are drawn at the user's opacity.
@property(nonatomic, assign) BOOL translucent;
/// Imported skins are aspect-fitted in the full view bounds (Delta rules);
/// default skins are generated at the exact view size (mapping == view).
@property(nonatomic, assign) BOOL generated;
/// Default extended edges of the representation (already applied to items).
@property(nonatomic, assign) LibretroInsets extendedEdges;
/// Default skins in portrait: opaque controller panel painted below the
/// game (0xAARRGGBB, 0 = no panel) over `panelFrame` (mapping units).
@property(nonatomic, assign) uint32_t panelColor;
@property(nonatomic, assign) LibretroRect panelFrame;
@end

/// A skin: NeoStation default (generated per layout) or imported .deltaskin
/// / .manicskin unpacked in its own directory.
@interface LibretroSkin : NSObject
/// Key used by selections and settings: the directory name of an imported
/// skin (see LibretroSkinIdentifierIsValid), "default" for NeoStation's.
@property(nonatomic, copy) NSString *installedIdentifier;
/// `identifier` field of info.json (reverse DNS), shown and used to detect
/// a replacement; never used in paths or setting keys.
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy, nullable) NSString *author;
/// NeoStation console ids this skin applies to (delta gbc -> gb and gbc).
@property(nonatomic, copy) NSArray<NSString *> *consoles;
@property(nonatomic, copy) NSString *gameTypeIdentifier;
@property(nonatomic, copy, nullable) NSString *directory;
@property(nonatomic, assign) BOOL debug;
@property(nonatomic, copy) NSArray<LibretroSkinRepresentation *> *representations;
/// Import report codes (see LibretroSkinWarning*), translated by Dart.
@property(nonatomic, copy) NSArray<NSString *> *warnings;

/// Parses <directory>/info.json (Delta / Provenance / Manic format, as the
/// real parsers read it, not the Provenance wiki):
/// - representations.{iphone|ipad}.{standard|edgeToEdge}.{portrait|landscape};
///   a device without display-type level means "standard"; splitView, tv,
///   stageManager and other Provenance display types are ignored;
/// - `gameScreenFrame` wins over `screens` (Delta) and becomes one screen;
/// - screens with `placement: "app"` keep normalized output frames (0-1 of
///   the game area); otherwise frames are in mapping units;
/// - items: frame required; inputs as array, single string (Manic), object
///   up/down/left/right (D-pad, or thumbstick when a `thumbstick` object
///   with name, width and height exists), object x/y (touch screen); item
///   images from `asset.normal` / `asset.name`; extendedEdges per edge
///   override the representation's;
/// - images are found by content (PDF, PNG, JPEG), not by key; a missing
///   size falls back to another size (warning); `__MACOSX` entries ignored.
///
/// `consoleGeometry` (sent by Dart from the core catalog) gives, per
/// console, its nominal picture size and, for dual-screen consoles, the
/// normalized regions of its screens in the core image:
///   {"gba": {"size": [240, 160]},
///    "nds": {"size": [256, 384], "regions": {"top": [0,0,1,0.5], "bottom": [0,0.5,1,0.5]}},
///    "3ds": {"size": [400, 480], "regions": {"top": [0,0,1,0.5], "bottom": [0.1,0.5,0.8,0.5]}}, ...}
/// Screen sources: nds uses the Delta inputFrames divided by the nominal
/// size; 3ds ignores inputFrames and takes "bottom" for the screen covered
/// by the touch-screen item, "top" for the other; other consoles use an
/// inputFrame only when it lies inside the nominal size (else the whole
/// picture, warning LibretroSkinWarningInputFrameIgnored).
/// On failure returns nil and sets `errorCode` (LibretroSkinError*).
+ (nullable instancetype)skinWithDirectory:(NSString *)directory
                           consoleGeometry:(nullable NSDictionary<NSString *, NSDictionary *> *)consoleGeometry
                                 errorCode:(NSString *_Nullable *_Nullable)errorCode;

/// NeoStation consoles for a gameTypeIdentifier (Delta, Manic, Provenance
/// spellings, normalised like Provenance: last dot component, lowercase,
/// without '-', '_' and spaces). Aliases: nds/ds -> nds; gbc/gb -> gb and
/// gbc; gba; nes; snes; n64; md/genesis/megadrive/mcd/32x -> md, mcd and
/// 32x; ms/sms/mastersystem -> sms; gg -> gg; sg1000; psx/ps1 -> psx; psp;
/// 3ds/threeds -> 3ds; arcade/fbneo/mame -> arcade. Empty when unsupported.
+ (NSArray<NSString *> *)consolesForGameTypeIdentifier:(NSString *)gameTypeIdentifier;

/// Representation for an orientation. iPhone: edgeToEdge -> standard, or
/// standard -> edgeToEdge. iPad (DeltaCore): ipad.standard, then iPhone
/// edgeToEdge, then iPhone standard (the `edgeToEdge` argument is ignored
/// on iPad). No orientation fallback: nil when the orientation is missing.
/// The caller takes the orientation from the view bounds (width > height
/// is landscape), never from the device, and decides edgeToEdge only once
/// the view is in a window (safe area bottom inset > 0).
- (nullable LibretroSkinRepresentation *)representationForOrientation:(LibretroSkinOrientation)orientation
                                                                  iPad:(BOOL)iPad
                                                            edgeToEdge:(BOOL)edgeToEdge;

/// "portrait", "landscape" orientations available for this device class.
- (NSArray<NSString *> *)orientationsForIPad:(BOOL)iPad;

/// Dictionary for Dart: {identifier, installedIdentifier, name, author
/// (absent when unknown), consoles, gameTypeIdentifier, orientations:
/// {iphone: [...], ipad: [...]}, warnings: [...], debug}.
- (NSDictionary<NSString *, id> *)summary;

@end

/// Identifier of an installed skin directory (Dart names it after the
/// archive's SHA-256: 16 lowercase hex characters). Only [a-z0-9-] are
/// allowed, so frontend setting keys built from it never contain dots.
FOUNDATION_EXPORT BOOL LibretroSkinIdentifierIsValid(NSString *identifier);

/// Import errors (skin refused).
FOUNDATION_EXPORT NSString *const LibretroSkinErrorInfoMissing;         // SKIN_INFO_MISSING
FOUNDATION_EXPORT NSString *const LibretroSkinErrorInfoInvalid;         // SKIN_INFO_INVALID
FOUNDATION_EXPORT NSString *const LibretroSkinErrorFieldMissing;        // SKIN_FIELD_MISSING
FOUNDATION_EXPORT NSString *const LibretroSkinErrorConsoleUnsupported;  // SKIN_CONSOLE_UNSUPPORTED
FOUNDATION_EXPORT NSString *const LibretroSkinErrorNoRepresentation;    // SKIN_NO_REPRESENTATION
FOUNDATION_EXPORT NSString *const LibretroSkinErrorNoPhoneOrTablet;     // SKIN_NO_DEVICE
/// Import warnings (skin accepted).
FOUNDATION_EXPORT NSString *const LibretroSkinWarningOrientationMissing;  // SKIN_WARN_ORIENTATION_MISSING
FOUNDATION_EXPORT NSString *const LibretroSkinWarningAssetMissing;        // SKIN_WARN_ASSET_MISSING
FOUNDATION_EXPORT NSString *const LibretroSkinWarningUnknownInputs;       // SKIN_WARN_UNKNOWN_INPUTS
FOUNDATION_EXPORT NSString *const LibretroSkinWarningFiltersIgnored;      // SKIN_WARN_FILTERS_IGNORED
FOUNDATION_EXPORT NSString *const LibretroSkinWarningInputFrameIgnored;   // SKIN_WARN_INPUT_FRAME_IGNORED
FOUNDATION_EXPORT NSString *const LibretroSkinWarningItemsDropped;        // SKIN_WARN_ITEMS_DROPPED
FOUNDATION_EXPORT NSString *const LibretroSkinWarningDebugMissing;        // SKIN_WARN_DEBUG_MISSING
FOUNDATION_EXPORT NSString *const LibretroSkinWarningNoTouchScreen;       // SKIN_WARN_TOUCHSCREEN_UNSUPPORTED

NS_ASSUME_NONNULL_END
