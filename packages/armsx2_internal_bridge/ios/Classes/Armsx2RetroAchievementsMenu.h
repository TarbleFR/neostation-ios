#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^Armsx2RetroAchievementsReadState)(
    void (^completion)(NSDictionary<NSString*, id>* _Nullable state));
typedef void (^Armsx2RetroAchievementsCommand)(
    NSString* command, id _Nullable value,
    void (^completion)(BOOL success, NSString* message));

/// NeoStation-owned RetroAchievements UI for the embedded ARMSX2 core.
/// It intentionally mirrors DolphinSessionMenu's inset-grouped selection style,
/// while all account/settings operations remain implemented by ARMSX2 upstream.
@interface Armsx2RetroAchievementsMenu : UITableViewController
@property(nonatomic, copy, nullable) NSString* gameTitle;
@property(nonatomic, copy) NSString* localeIdentifier;
@property(nonatomic, copy) Armsx2RetroAchievementsReadState readState;
@property(nonatomic, copy) Armsx2RetroAchievementsCommand performCommand;
@end

NS_ASSUME_NONNULL_END
