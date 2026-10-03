#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN
@interface RetroArchSessionMenu : UITableViewController
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, copy) NSString* gameTitle;
@property(nonatomic, assign) uint64_t capabilities;
@property(nonatomic, copy) NSString* cheatsPath;
@property(nonatomic, copy) void (^performCommand)(NSDictionary* request,
                                             void (^completion)(NSDictionary* response));
@property(nonatomic, copy) dispatch_block_t resumeGame;
@property(nonatomic, copy) dispatch_block_t quitGame;
- (void)completePendingOperation:(NSDictionary*)response;
@end
NS_ASSUME_NONNULL_END
