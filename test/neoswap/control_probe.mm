// Real plugin control-plane execution in an iOS Simulator application.
// Flutter messaging alone is stubbed; no emulation or device RAM claim.
#import <UIKit/UIKit.h>
#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
NSObject* const FlutterMethodNotImplemented=nil;
@implementation FlutterMethodCall
@end
@implementation FlutterMethodChannel
+ (instancetype)methodChannelWithName:(NSString*)name binaryMessenger:(NSObject<FlutterBinaryMessenger>*)messenger {
    (void)name; (void)messenger; return [self new];
}
@end
@interface ProbeRegistrar:NSObject<FlutterPluginRegistrar>
@property(nonatomic,strong) id delegate;
@end
@implementation ProbeRegistrar
- (NSObject<FlutterBinaryMessenger>*)messenger { return (NSObject<FlutterBinaryMessenger>*)self; }
- (void)addMethodCallDelegate:(id)delegate channel:(FlutterMethodChannel*)channel { (void)channel; self.delegate=delegate; }
@end
static NeoSwapPlugin* plugin;
static void* live;
static int checks=0;
static void Finish(BOOL success,NSString* detail) {
    NSString* docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary* report=@{@"success":@(success),@"checks":@(checks),@"detail":detail,
        @"kind":@"iOS simulator plugin control plane; not RPCS3 emulation",
        @"os":NSProcessInfo.processInfo.operatingSystemVersionString};
    NSData* data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[docs stringByAppendingPathComponent:@"result.json"] atomically:YES];
    NSLog(@"NEOSWAP_PROBE %@ %@",success ? @"PASS":@"FAIL",detail);
    exit(success ? 0:1);
}
static void Check(BOOL value,NSString* detail) { ++checks; if(!value) Finish(NO,detail); }
static void Request(NSString* method,id arguments,void(^next)(NSDictionary*)) {
    FlutterMethodCall* call=[FlutterMethodCall new];call.method=method;call.arguments=arguments;
    [plugin handleMethodCall:call result:^(id result) {
        Check(NSThread.isMainThread,@"response must run on main queue");
        Check([result isKindOfClass:NSDictionary.class],@"dictionary response");next(result);
    }];
}
static NSDictionary* Owner(NSDictionary* result,NSString* name) {
    for(NSDictionary* owner in result[@"owners"]) if([owner[@"owner"] isEqual:name]) return owner;
    Finish(NO,@"missing owner");return @{};
}
static void RunProbe(void) {
    // An old opt-out from the previous candidate cannot disable the new policy.
    [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"NeoSwapCapacityMiBV1"];
    ProbeRegistrar* first=[ProbeRegistrar new];ProbeRegistrar* second=[ProbeRegistrar new];
    [NeoSwapPlugin registerWithRegistrar:first];[NeoSwapPlugin registerWithRegistrar:second];
    Check(first.delegate==second.delegate,@"single plugin/broker across two registrars");plugin=first.delegate;
    Request(@"snapshot",nil,^(NSDictionary* initial) {
        Check([initial[@"capacityBytes"] unsignedLongLongValue]==8589934592ULL,@"automatic8GiB despite previous Off preference");
        Check([initial[@"configResult"] intValue]==0,@"automatic startup configuration");
        Check([initial[@"reservedVirtualBytes"] unsignedLongLongValue]==0,@"configuration reserves no synthetic 8GiB address arena");
        Check([initial[@"memoryDonationSupported"] boolValue]==NO,@"helper process donation not misrepresented");
        Check(initial[@"donatedMemoryBytes"]==NSNull.null,@"unsupported donation is unavailable, not fake zero or allocated bytes");
        Check([initial[@"allocatedDiskBytes"] unsignedLongLongValue]==0,@"configuration reserves no disk data");
        const NeoSwapAPI* api=NeoSwap_GetAPI(1);
        Check(api->enabled(NEOSWAP_RPCS3),@"RPCS3 allocation path enabled without opening settings");
        Check(api->allocate(NEOSWAP_RPCS3,NEOSWAP_CPU_DATA,2*1024*1024,65536,&live)==0,@"automatic live broker allocation");
        memset(live,0x63,2*1024*1024);
        Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* busy) {
            Check([busy[@"result"] intValue]==NEOSWAP_BUSY,@"capacity exercise refuses live game ownership");
            Check(!busy[@"capacityProbe"],@"refused exercise has no stale success report");
            Request(@"probe",nil,^(NSDictionary* probed) {
                Check([probed[@"result"] intValue]==0,@"8MiB production integrity exercise");
                Check([Owner(probed,@"probe")[@"allocationCount"] unsignedLongLongValue]==1,@"separate diagnostic owner");
                Check([Owner(probed,@"probe")[@"liveBytes"] unsignedLongLongValue]==0,@"probe fully released");
                Check([Owner(probed,@"rpcs3")[@"liveBytes"] unsignedLongLongValue]==2*1024*1024,@"game counter unchanged");
                Check([probed[@"reservedVirtualBytes"] unsignedLongLongValue]==2*1024*1024,@"only the actual live file buffer owns an address region");
                for(size_t i=0;i<2*1024*1024;i++)if(((unsigned char*)live)[i]!=0x63)Finish(NO,@"live data changed");
                Check(api->release(live)==0,@"release real block");live=nullptr;
                Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* checked) {
                    Check([checked[@"result"] intValue]==0,@"64MiB write/sync/reload via production plugin");
                    NSDictionary* report=checked[@"capacityProbe"];
                    Check([report[@"dataVerified"] boolValue],@"capacity data verified");
                    Check([report[@"requestedBytes"] unsignedLongLongValue]==64*1024*1024,@"exact requested capacity");
                    Check([report[@"samples"] count]==5,@"before/write/sync/verify/release measurements");
                    Check([checked[@"liveBlocks"] unsignedLongLongValue]==0,@"capacity exercise releases every block");
                    Request(@"capacityProbe",@{@"sizeMiB":@16384},^(NSDictionary* invalid) {
                        Check([invalid[@"result"] intValue]==NEOSWAP_INVALID,@"over8GiB exercise rejected");
                        Check(!invalid[@"capacityProbe"],@"invalid retry cannot reuse old success");
                        FlutterMethodCall* legacy=[FlutterMethodCall new];legacy.method=@"configure";legacy.arguments=@{@"capacityMiB":@0};
                        [plugin handleMethodCall:legacy result:^(id result) {
                            Check(result==FlutterMethodNotImplemented,@"old activation command unavailable");
                            Request(@"snapshot",nil,^(NSDictionary* final) {
                                Check([final[@"capacityBytes"] unsignedLongLongValue]==8589934592ULL,@"automatic policy remains8GiB after diagnostics");
                                Check(api->enabled(NEOSWAP_RPCS3),@"runtime path remains enabled");
                                Check([final[@"liveBlocks"] unsignedLongLongValue]==0,@"no leaked blocks");
                                Check([final[@"reservedVirtualBytes"] unsignedLongLongValue]==0,@"released exact allocation regions leave no reserved address arena");
                                Check([Owner(final,@"probe")[@"allocationCount"] unsignedLongLongValue]==2,@"diagnostic ownership isolated");
                                NSString* log=[NSString stringWithContentsOfFile:final[@"diagnosticPath"] encoding:NSUTF8StringEncoding error:nil];
                                Check([log containsString:@"process_start"] && [log containsString:@"capacity_probe"],@"diagnostic events written");
                                Finish(YES,@"automatic8GiB; legacy Off ignored; no activation command; live-game refusal;64MiB integrity; ownership; stale evidence rejection; cleanup");
                            });
                        }];
                    });
                });
            });
        });
    });
}
@interface ProbeAppDelegate:UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)app;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_main_queue(),^{RunProbe();});return YES;
}
@end
int main(int argc,char** argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(ProbeAppDelegate.class)); } }
