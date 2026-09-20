#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^Armsx2SessionReadSnapshot)(
    void (^completion)(NSDictionary<NSString*, id>* _Nullable snapshot));
typedef void (^Armsx2SessionCommand)(
    NSString* command, id _Nullable value,
    void (^completion)(BOOL success, NSString* message));
typedef void (^Armsx2SessionRAReadState)(
    void (^completion)(NSDictionary<NSString*, id>* _Nullable state));
typedef void (^Armsx2SessionRACommand)(
    NSString* command, id _Nullable value,
    void (^completion)(BOOL success, NSString* message));

/// Full-screen in-game settings architecture for embedded ARMSX2.
///
/// The navigation model intentionally mirrors DolphinSessionMenu: an
/// inset-grouped root page, pushed sub-pages, checkmarked choice pages, and
/// explicit Resume/Quit actions while the game view remains attached below.
@interface Armsx2SessionMenu : UITableViewController
@property(nonatomic, copy) NSString* gameTitle;
@property(nonatomic, copy) Armsx2SessionReadSnapshot readSnapshot;
@property(nonatomic, copy) Armsx2SessionCommand performCommand;
@property(nonatomic, copy) Armsx2SessionRAReadState readRetroAchievements;
@property(nonatomic, copy) Armsx2SessionRACommand performRetroAchievementsCommand;
@property(nonatomic, copy) dispatch_block_t resumeGame;
@property(nonatomic, copy) dispatch_block_t quitGame;
@end

NS_ASSUME_NONNULL_END
