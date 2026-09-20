#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^Rpcs3SessionCommand)(
    NSString* command,
    id _Nullable value,
    void (^completion)(BOOL success, NSString* message));

typedef void (^Rpcs3SessionReadStates)(
    void (^completion)(NSDictionary<NSString*, id>* _Nullable state));

typedef void (^Rpcs3SessionStateCommand)(
    NSInteger slot,
    BOOL load,
    NSString* _Nullable identifier,
    void (^completion)(BOOL success, NSString* message));

@interface Rpcs3SessionMenu : UITableViewController
@property(nonatomic, copy) NSString* localeIdentifier;
@property(nonatomic, copy) NSString* gameTitle;
@property(nonatomic, assign) BOOL performanceVisible;
@property(nonatomic, assign) BOOL touchControlsVisible;
@property(nonatomic, copy) NSArray<NSDictionary<NSString*, NSString*>*>* languageChoices;
@property(nonatomic, copy) Rpcs3SessionCommand performCommand;
@property(nonatomic, copy) Rpcs3SessionReadStates readStates;
@property(nonatomic, copy) Rpcs3SessionStateCommand performStateOperation;
@property(nonatomic, copy) dispatch_block_t resumeGame;
@property(nonatomic, copy) dispatch_block_t quitGame;
@end

NS_ASSUME_NONNULL_END
