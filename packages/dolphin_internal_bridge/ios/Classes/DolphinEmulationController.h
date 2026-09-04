#import <MetalKit/MetalKit.h>
#import <UIKit/UIKit.h>

@interface DOLDolphinViewController : UIViewController
@property(nonatomic, readonly) MTKView* metalView;
@property(nonatomic, copy) NSString* systemFolder;
@property(nonatomic, copy, nullable) dispatch_block_t closeHandler;
@property(nonatomic, copy, nullable) void (^pauseHandler)(BOOL paused);
- (void)beginInput;
- (void)endInput;
@end
