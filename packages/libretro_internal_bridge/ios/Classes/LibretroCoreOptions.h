#import <Foundation/Foundation.h>

#include "libretro.h"

NS_ASSUME_NONNULL_BEGIN

/// One option declared by a libretro core, normalised across the option
/// API versions (SET_VARIABLES, SET_CORE_OPTIONS v1/v2 and their _INTL
/// variants).
@interface LibretroCoreOption : NSObject
@property(nonatomic, copy, readonly) NSString *key;
@property(nonatomic, copy, readonly) NSString *coreDescription;
@property(nonatomic, copy, readonly) NSArray<NSString *> *values;
@property(nonatomic, copy, readonly) NSArray<NSString *> *valueLabels;
@property(nonatomic, copy, readonly) NSString *defaultValue;
@property(nonatomic, assign) BOOL visible;
@end

/// Stores the options a core declares and the values chosen for them.
///
/// Values persist as JSON, one file per core, so the same choice applies to
/// every game of that core. Overrides passed by NeoStation for a session
/// (curated, translated settings) win over the stored values for that
/// session only.
@interface LibretroCoreOptions : NSObject

- (instancetype)initWithStorePath:(NSString *)storePath NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property(nonatomic, copy, readonly) NSArray<LibretroCoreOption *> *options;
@property(nonatomic, assign, readonly) BOOL updatePending;
@property(nonatomic, assign, nullable) retro_core_options_update_display_callback_t updateDisplayCallback;

/// Session-only values that take precedence over stored ones (for instance
/// interpreter CPU cores while JIT is unavailable). May be called before
/// the core declares its options. Sets `updatePending` when the effective
/// value of an already declared option changes.
- (void)applySessionOverrides:(NSDictionary<NSString *, NSString *> *)overrides;
/// Same as applySessionOverrides:, and `setValue:forKey:persist:` then
/// refuses these keys for the rest of the session (returns NO, nothing
/// stored).
- (void)lockSessionOverrides:(NSDictionary<NSString *, NSString *> *)overrides;
/// NeoStation defaults, used only while the user has stored no value. Sets
/// `updatePending` when the effective value of a declared option changes.
- (void)applyDefaults:(NSDictionary<NSString *, NSString *> *)defaults;
/// YES for keys passed to lockSessionOverrides:.
- (BOOL)isLockedKey:(NSString *)key;

- (BOOL)declareVariables:(const struct retro_variable *)variables;
- (BOOL)declareDefinitions:(const struct retro_core_option_definition *)definitions
                     local:(const struct retro_core_option_definition *_Nullable)local;
- (BOOL)declareV2:(const struct retro_core_options_v2 *)options
            local:(const struct retro_core_options_v2 *_Nullable)local;
- (void)setDisplay:(const struct retro_core_option_display *)display;

/// GET_VARIABLE: the returned pointer stays valid until the value of that
/// key changes or the store is released.
- (nullable const char *)valueForKey:(const char *)key;
/// SET_VARIABLE (from the core) and user changes from the session menu.
- (BOOL)setValue:(NSString *)value forKey:(NSString *)key persist:(BOOL)persist;
/// GET_VARIABLE_UPDATE: returns YES once after a change, then clears.
- (BOOL)consumeUpdate;

- (void)save;

@end

NS_ASSUME_NONNULL_END
