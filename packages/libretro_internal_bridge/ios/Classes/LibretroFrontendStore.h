#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Where a resolved value came from.
typedef NS_ENUM(NSInteger, LibretroSettingScope) {
  LibretroSettingScopeDefault = 0,
  LibretroSettingScopeConsole = 1,
  LibretroSettingScopeGame = 2,
};

/// Keys stored by the frontend (values are JSON types):
///   skin.portrait, skin.landscape            NSString skin identifier ("default" = NeoStation skin)
///   screenFormat                             NSString ("original", "4:3", "16:9", "16:10", "stretch")
///   screenArrangement.portrait / .landscape  NSString (DS/3DS default skins, see LibretroDefaultSkins)
///   screensSwapped                           NSNumber BOOL (DS/3DS default skins)
///   shader.enabled                           NSNumber BOOL
///   shader.preset                            NSString preset identifier
///   shader.parameters                        NSDictionary<NSString *, NSNumber *>
///   controls.gamepad                         NSDictionary element -> logical input
///   controls.touch.<skinId>                  NSDictionary itemId -> NSArray<NSString *> logical inputs
///   controls.layout.<skinId>.<orientation>   NSDictionary itemId -> {dx, dy, scale}
///   controls.opacity                         NSNumber 0.15 ... 1.0
FOUNDATION_EXPORT NSString *const LibretroSettingSkinPortrait;
FOUNDATION_EXPORT NSString *const LibretroSettingSkinLandscape;
FOUNDATION_EXPORT NSString *const LibretroSettingScreenFormat;
FOUNDATION_EXPORT NSString *const LibretroSettingArrangementPortrait;
FOUNDATION_EXPORT NSString *const LibretroSettingArrangementLandscape;
FOUNDATION_EXPORT NSString *const LibretroSettingScreensSwapped;
FOUNDATION_EXPORT NSString *const LibretroSettingShaderEnabled;
FOUNDATION_EXPORT NSString *const LibretroSettingShaderPreset;
FOUNDATION_EXPORT NSString *const LibretroSettingShaderParameters;
FOUNDATION_EXPORT NSString *const LibretroSettingGamepad;
FOUNDATION_EXPORT NSString *const LibretroSettingOpacity;
FOUNDATION_EXPORT NSString *LibretroSettingTouchRemapKey(NSString *skinId);
FOUNDATION_EXPORT NSString *LibretroSettingLayoutKey(NSString *skinId, NSString *orientation);

/// Persistent frontend preferences of the embedded engine, per console with
/// optional per-game exceptions. Resolution order (documented to the user):
/// game value, then console value, then NeoStation default (nil).
///
/// One JSON file per console: <directory>/<console>.json
///   {"version": 1, "console": {key: value}, "games": {gameKey: {key: value}}}
/// written atomically. The single writer is native code: Dart reads and
/// writes through the method channel, so the app and a running game never
/// write the same file concurrently. Thread-safe.
@interface LibretroFrontendStore : NSObject

/// Shared instance for a directory (one per path for the process lifetime).
+ (instancetype)storeWithDirectory:(NSString *)directory;

@property(nonatomic, copy, readonly) NSString *directory;

/// Resolved value: the game's when `gameKey` has one, else the console's,
/// else nil. `scope` (optional) receives where it came from.
- (nullable id)valueForKey:(NSString *)key
                   console:(NSString *)console
                      game:(nullable NSString *)gameKey
                     scope:(nullable LibretroSettingScope *)scope;

/// Value stored exactly at one scope (no fallback); nil when absent.
- (nullable id)storedValueForKey:(NSString *)key console:(NSString *)console game:(nullable NSString *)gameKey;

/// Stores `value` for the console (`gameKey` nil) or for one game. A nil
/// value removes the key at that scope. Values that are not JSON types are
/// refused (returns NO). Writes the file before returning.
- (BOOL)setValue:(nullable id)value
          forKey:(NSString *)key
         console:(NSString *)console
            game:(nullable NSString *)gameKey;

/// Removes every key starting with one of `prefixes` (all keys when nil) at
/// one scope: "Rétablir les réglages par défaut".
- (void)resetConsole:(NSString *)console game:(nullable NSString *)gameKey prefixes:(nullable NSArray<NSString *> *)prefixes;

/// After a skin is deleted: removes skin selections, touch remaps and layout
/// overrides naming it, at every scope of every console file.
- (void)forgetSkin:(NSString *)skinId;

/// The console file as stored, for Dart ({"console": {...}, "games": {...}}).
- (NSDictionary<NSString *, id> *)snapshotForConsole:(NSString *)console;

@end

NS_ASSUME_NONNULL_END
