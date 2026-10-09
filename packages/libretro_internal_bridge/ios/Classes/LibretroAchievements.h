#import <Foundation/Foundation.h>

@class LibretroCoreHost;

NS_ASSUME_NONNULL_BEGIN

/// RetroAchievements for embedded libretro games, through rcheevos'
/// rc_client: login with the emulator token (kept in the Keychain, the
/// password never is), game identification by hash, per-frame evaluation on
/// the emulation thread and memory reads through the core's memory maps.
/// Softcore only: save states stay available.
@interface LibretroAchievements : NSObject

- (instancetype)initWithConsoleId:(unsigned)consoleId host:(LibretroCoreHost *)host;

+ (BOOL)enabled;
+ (void)setEnabled:(BOOL)enabled;
+ (BOOL)hasStoredLogin;

@property(nonatomic, copy, nullable) void (^unlocked)(NSString *title);
@property(nonatomic, copy, nullable) dispatch_block_t stateChanged;
@property(nonatomic, readonly) BOOL loggedIn;
@property(nonatomic, readonly, nullable) NSString *username;
@property(nonatomic, readonly) BOOL gameLoaded;
@property(nonatomic, readonly) unsigned totalCount;
@property(nonatomic, readonly) unsigned unlockedCount;

/// Emulation thread, after the content is loaded.
- (void)startWithContentPath:(NSString *)path;
/// Main thread. The password is sent once to RetroAchievements.
- (void)loginWithUsername:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(BOOL success))completion;
- (void)logout;

- (void)doFrame;
- (void)idle;
- (void)resetGame;
- (void)shutdown;

@end

NS_ASSUME_NONNULL_END
