#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Launch description assembled by Dart. Every user-visible label arrives
/// translated in `uiText`; native code shows no text of its own.
@interface LibretroSessionConfiguration : NSObject
@property(nonatomic, copy) NSString *corePath;
@property(nonatomic, copy) NSString *contentPath;
@property(nonatomic, copy) NSString *gameTitle;
@property(nonatomic, copy) NSString *profile;
@property(nonatomic, copy) NSString *systemDirectory;
@property(nonatomic, copy) NSString *saveDirectory;
@property(nonatomic, copy) NSString *stateDirectory;
@property(nonatomic, copy) NSString *optionsDirectory;
@property(nonatomic, copy) NSString *cheatsDirectory;
@property(nonatomic, copy) NSString *cacheDirectory;
@property(nonatomic, copy) NSString *uiLocale;
@property(nonatomic, assign) unsigned retroLanguage;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *uiText;
/// NeoStation defaults for core options, used until the user changes them.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *optionDefaults;
/// Interpreter settings forced while cores cannot use JIT.
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *noJitOverrides;
/// Curated, translated settings: [{key, label, values: [{value, label}]}].
@property(nonatomic, copy) NSArray<NSDictionary *> *coreSettings;
@property(nonatomic, assign) BOOL achievementsAllowed;
@property(nonatomic, assign) unsigned achievementsConsoleId;
/// RETRO_HW_CONTEXT_* answered to GET_PREFERRED_HW_RENDER for this core.
@property(nonatomic, assign) unsigned preferredHardwareContext;
@end

/// One embedded game: core host on its own emulation thread, presentation,
/// audio, input, menu, save states, cheats and RetroAchievements.
@interface LibretroSession : NSObject

- (instancetype)initWithConfiguration:(LibretroSessionConfiguration *)configuration;

/// Presents the game over `presenter` and loads the content. `completion`
/// runs once on the main thread with {success, code, message, ...}.
- (void)startFromViewController:(UIViewController *)presenter
                     completion:(void (^)(NSDictionary<NSString *, id> *result))completion;

/// Saves, unloads the core and dismisses the game. `completion` runs on the
/// main thread after the view controller is gone.
- (void)stopWithCompletion:(nullable dispatch_block_t)completion;

@property(nonatomic, readonly) BOOL active;
@property(nonatomic, copy, nullable) dispatch_block_t endedHandler;
@property(nonatomic, readonly) NSArray<NSString *> *recentLog;

@end

NS_ASSUME_NONNULL_END
