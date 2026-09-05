#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface DolphinSessionMenu : UITableViewController
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, assign) BOOL wii;
@property(nonatomic, copy) NSString* gameTitle;
@property(nonatomic, assign) BOOL stateActionsAvailable;
@property(nonatomic, assign) NSInteger slot;
@property(nonatomic, copy) void (^readSettings)(BOOL wii, NSInteger slot, void (^completion)(NSDictionary* _Nullable));
@property(nonatomic, copy) void (^applySettings)(NSDictionary* request, void (^completion)(BOOL));
@property(nonatomic, copy) void (^readStates)(void (^completion)(NSDictionary* _Nullable));
@property(nonatomic, copy) void (^performStateOperation)(NSInteger slot, BOOL load, void (^completion)(BOOL));
@property(nonatomic, copy, nullable) void (^readRecording)(void (^completion)(NSDictionary* _Nullable));
@property(nonatomic, copy, nullable) void (^toggleRecording)(void (^completion)(BOOL));
@property(nonatomic, copy, nullable) dispatch_block_t shareRecording;
@property(nonatomic, copy) dispatch_block_t resumeGame;
@property(nonatomic, copy) dispatch_block_t quitGame;
@property(nonatomic, copy) dispatch_block_t restartGame;
- (void)refreshRecordingStatus;
@end
NS_ASSUME_NONNULL_END
