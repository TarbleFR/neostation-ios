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
static void CapacityCases(void(^done)(void)) {
    Request(@"configure",@{@"capacityMiB":@8192},^(NSDictionary* configured) {
        Check([configured[@"result"] intValue]==0 && [configured[@"capacityBytes"] unsignedLongLongValue]==8589934592ULL,@"8GiB budget round trip");
        const NeoSwapAPI* api=NeoSwap_GetAPI(1);
        Check(api->allocate(NEOSWAP_RPCS3,NEOSWAP_CPU_DATA,2*1024*1024,65536,&live)==0,@"live block before capacity exercise");
        Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* busy) {
            Check([busy[@"result"] intValue]==NEOSWAP_BUSY,@"capacity exercise refuses live game ownership");
            Check(api->release(live)==0,@"release before capacity exercise");live=nullptr;
            Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* checked) {
                Check([checked[@"result"] intValue]==0,@"64MiB production-plugin capacity exercise");
                NSDictionary* report=checked[@"capacityProbe"];
                Check([report[@"dataVerified"] boolValue] && [report[@"requestedBytes"] unsignedLongLongValue]==64*1024*1024,@"new capacity report verifies requested bytes");
                Check([report[@"samples"] count]==5,@"write/sync/reload/release measurements");
                Check([checked[@"liveBlocks"] unsignedLongLongValue]==0,@"capacity exercise releases every block");
                Request(@"capacityProbe",@{@"sizeMiB":@16384},^(NSDictionary* invalid) {
                    Check([invalid[@"result"] intValue]==NEOSWAP_INVALID && !invalid[@"capacityProbe"],@"invalid new test cannot reuse old success evidence");
                    done();
                });
            });
        });
    });
}
static void RunProbe(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"NeoSwapCapacityMiBV1"];
    ProbeRegistrar* first=[ProbeRegistrar new];ProbeRegistrar* second=[ProbeRegistrar new];
    [NeoSwapPlugin registerWithRegistrar:first];[NeoSwapPlugin registerWithRegistrar:second];
    Check(first.delegate==second.delegate,@"single plugin/broker across two registrars");plugin=first.delegate;
    Request(@"snapshot",nil,^(NSDictionary* s) {
        Check([s[@"capacityBytes"] unsignedLongLongValue]==0,@"disabled by default");
        Check([s[@"configResult"] intValue]==0,@"initial configuration");
        Request(@"configure",@{@"capacityMiB":@512},^(NSDictionary* configured) {
            Check([configured[@"result"] intValue]==0,@"enable 512 MiB");
            Check([NSUserDefaults.standardUserDefaults integerForKey:@"NeoSwapCapacityMiBV1"]==512,@"persist success");
            const NeoSwapAPI* api=NeoSwap_GetAPI(1);
            Check(api->allocate(NEOSWAP_RPCS3,NEOSWAP_CPU_DATA,2*1024*1024,65536,&live)==0,@"live broker allocation");
            memset(live,0x63,2*1024*1024);
            Request(@"configure",@{@"capacityMiB":@1024},^(NSDictionary* busy) {
                Check([busy[@"result"] intValue]==NEOSWAP_BUSY,@"live ownership blocks reconfiguration");
                Check([NSUserDefaults.standardUserDefaults integerForKey:@"NeoSwapCapacityMiBV1"]==512,@"busy does not persist");
                Request(@"configure",@{@"capacityMiB":@513},^(NSDictionary* invalid) {
                    Check([invalid[@"result"] intValue]==NEOSWAP_INVALID,@"reject invalid capacity");
                    Request(@"probe",nil,^(NSDictionary* probed) {
                        Check([probed[@"result"] intValue]==0,@"8 MiB write/sync/read/release");
                        Check([Owner(probed,@"probe")[@"allocationCount"] unsignedLongLongValue]==1,@"separate probe owner");
                        Check([Owner(probed,@"probe")[@"liveBytes"] unsignedLongLongValue]==0,@"probe fully freed");
                        Check([Owner(probed,@"rpcs3")[@"liveBytes"] unsignedLongLongValue]==2*1024*1024,@"real owner not inflated by probe");
                        for(size_t i=0;i<2*1024*1024;i++) if(((unsigned char*)live)[i]!=0x63) Finish(NO,@"live data changed");
                        Check(api->release(live)==0,@"release real block");live=nullptr;
                        CapacityCases(^{
                        Request(@"configure",@{@"capacityMiB":@0},^(NSDictionary* disabled) {
                            Check([disabled[@"result"] intValue]==0,@"disable after release");
                            Check([disabled[@"liveBlocks"] unsignedLongLongValue]==0,@"no leaked blocks");
                            Check(!api->enabled(NEOSWAP_RPCS3),@"allocation path off");
                            Request(@"probe",nil,^(NSDictionary* off) {
                                Check([off[@"result"] intValue]==NEOSWAP_DISABLED,@"probe obeys disabled configuration");
                                Check([off[@"configResult"] intValue]==0,@"configuration status remains accurate");
                                NSString* path=off[@"diagnosticPath"];
                                NSString* log=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                                Check([log containsString:@"process_start"] && [log containsString:@"probe"],@"diagnostic events written");
                                Finish(YES,@"single instance; persistence; live-block refusal; 8GiB budget;64MiB capacity integrity; stale evidence rejection; cleanup");
                            });
                        });
                        });
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
