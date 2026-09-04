#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface DolphinSessionMenu : UITableViewController
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, assign) BOOL wii;
@property(nonatomic, assign) NSInteger slot;
@property(nonatomic, copy) void (^readSettings)(BOOL wii, NSInteger slot, void (^completion)(NSDictionary* _Nullable));
@property(nonatomic, copy) void (^applySettings)(NSDictionary* request, void (^completion)(BOOL));
@property(nonatomic, copy) dispatch_block_t resumeGame;
@property(nonatomic, copy) dispatch_block_t quitGame;
@end
NS_ASSUME_NONNULL_END
