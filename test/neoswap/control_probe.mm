// Real plugin control-plane execution in an iOS Simulator application.
// Flutter messaging alone is stubbed; no emulation or device RAM claim.
#import <UIKit/UIKit.h>
#import "NeoSwapPlugin.h"
#import "NeoSwap.h"
#include "NeoSwapHost.h"
#include "NeoSwapMemorySamples.h"
#include <cerrno>
@interface NeoSwapPlugin (MemoryLogProbe)
@property(nonatomic, strong) dispatch_queue_t queue;
- (void)appendRecord:(NSDictionary*)record;
@end
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
static BOOL memoryLogsPassed=NO;
static void Finish(BOOL success,NSString* detail) {
    NSString* docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    NSDictionary* report=@{@"success":@(success),@"checks":@(checks),@"detail":detail,
        @"kind":@"iOS simulator plugin control plane; not RPCS3 emulation",
        @"memoryLogsPassed":@(memoryLogsPassed), @"realRPCS3GameplayValidated":@NO,
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
static void MemoryProbe(NSDictionary* initial) {
    Check([initial[@"liveBytes"] unsignedLongLongValue]==0,@"memory sampling starts with no allocator loan");
    Check(NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3,1)==0,@"signal observed session without running an emulator");
    const uint64_t warningsBefore = [initial[@"iosMemoryWarningCount"] unsignedLongLongValue];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        Request(@"snapshot",nil,^(NSDictionary* sample) {
            Check([sample[@"iosMemoryWarningCount"] unsignedLongLongValue]>=warningsBefore+1,@"active RPCS3 warning persisted");
            NSDictionary* profile=sample[@"memoryProfile"];
            Check([profile[@"sampledSessionActive"] boolValue],@"active sampling despite zero loans");
            Check([profile[@"intervalMs"] intValue]==1000,@"one-second active cadence");
            Check([profile[@"measurementValid"] boolValue] && [profile[@"validSamples"] intValue]>=3,@"real TASK_VM_INFO measurements");
            Check([profile[@"footprintPeakBytes"] unsignedLongLongValue]>0,@"measured sampled footprint peak");
            NSString* log=[NSString stringWithContentsOfFile:sample[@"diagnosticPath"] encoding:NSUTF8StringEncoding error:nil];
            NSUInteger periodic=0;BOOL start=NO;
            for(NSString* line in [log componentsSeparatedByString:@"\n"]) {
                NSDictionary* row=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if([row[@"event"] isEqual:@"rpcs3_memory_session_start"])start=YES;
                if([row[@"event"] isEqual:@"sample"] && [row[@"memoryProfile"][@"sampledSessionActive"] boolValue]) {
                    ++periodic;
                    Check([row[@"liveBytes"] unsignedLongLongValue]==0,@"zero-loan periodic log retained");
                }
            }
            Check(start && periodic>=2,@"start and repeated zero-loan samples written by production timer");
            Check(NeoSwap_SetOwnerSessionActive(NEOSWAP_RPCS3,0)==0,@"signal session end");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/2),dispatch_get_main_queue(),^{
                Request(@"snapshot",nil,^(NSDictionary* ended) {
                    NSString* finalLog=[NSString stringWithContentsOfFile:ended[@"diagnosticPath"] encoding:NSUTF8StringEncoding error:nil];
                    Check([finalLog containsString:@"rpcs3_memory_session_end"],@"session end logged without a live allocation");
                    NSString* docs=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
                    [finalLog writeToFile:[docs stringByAppendingPathComponent:@"memory-samples.jsonl"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
                    dispatch_async(plugin.queue,^{
                        @autoreleasepool {
                            NSString* payload=[@"" stringByPaddingToLength:60000 withString:@"x" startingAtIndex:0];
                            const auto limit=neostation::diagnostics::MemorySamples::maximum_file_bytes;
                            for(NSUInteger i=0;i<limit/payload.length+3;++i)
                                [plugin appendRecord:@{@"event":@"rotation_fixture",@"payload":payload}];
                            for(NSString* path in @[ended[@"diagnosticPath"],[ended[@"diagnosticPath"] stringByAppendingString:@".previous"]]) {
                                const auto size=[[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
                                Check(size>0 && size<=limit,@"both production logs exist and respect the configured rotation bound");
                            }
                            NSString* oversized=[@"" stringByPaddingToLength:65536 withString:@"x" startingAtIndex:0];
                            [plugin appendRecord:@{@"payload":oversized}];
                        }
                        dispatch_async(dispatch_get_main_queue(),^{
                            Request(@"snapshot",nil,^(NSDictionary* bounded) {
                                Check([bounded[@"diagnosticErrno"] intValue]==EOVERFLOW,@"oversized row refused with its real technical error");
                                Check([bounded[@"memoryProfile"][@"maximumRetainedLogBytes"] unsignedLongLongValue]==32*1024*1024,@"two-file retained log bound");
                                memoryLogsPassed=YES;
                                Finish(YES,@"automatic8GiB contract; integrity and ownership; real process samples with zero loans; session end; bounded log rotation");
                            });
                        });
                    });
                });
            });
        });
    });
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
#if !defined(NEOSWAP_TESTING)
        Check([initial[@"scope"] isEqual:@"rpcs3_only"],@"production scope is RPCS3 only");
        Check(![initial[@"diagnosticProbesAvailable"] boolValue],@"synthetic allocations absent from production");
        for(uint32_t owner=1;owner<NEOSWAP_OWNER_COUNT;++owner)
            Check(!NeoSwap_GetAPI(1)->enabled(owner),@"legacy owner disabled");
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        Request(@"probe",nil,^(NSDictionary* denied) {
            Check([denied[@"iosMemoryWarningCount"] unsignedLongLongValue]==0,@"warning outside RPCS3 ignored");
            Check([denied[@"result"] intValue]==NEOSWAP_DISABLED,@"production integrity allocation refused");
            Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* final) {
                Check([final[@"result"] intValue]==NEOSWAP_DISABLED,@"production capacity allocation refused");
                Check([final[@"allocationCount"] unsignedLongLongValue]==0,@"no synthetic allocation performed");
                Check([final[@"liveBytes"] unsignedLongLongValue]==0,@"no synthetic data retained");
                MemoryProbe(final);
            });
        });
        return;
#endif
        const NeoSwapAPI* api=NeoSwap_GetAPI(1);
        Check(api->enabled(NEOSWAP_RPCS3),@"RPCS3 allocation path enabled without opening settings");
        Check(api->allocate(NEOSWAP_RPCS3,NEOSWAP_CPU_DATA,2*1024*1024,65536,&live)==0,@"automatic live broker allocation");
        memset(live,0x63,2*1024*1024);
        Request(@"capacityProbe",@{@"sizeMiB":@64},^(NSDictionary* busy) {
            Check([busy[@"result"] intValue]==NEOSWAP_BUSY,@"capacity exercise refuses live game ownership");
            Check(!busy[@"capacityProbe"],@"refused exercise has no stale success report");
            Request(@"probe",nil,^(NSDictionary* probed) {
                Check([probed[@"result"] intValue]==0,@"8MiB test-only RPCS3 integrity exercise");
                Check([Owner(probed,@"probe")[@"allocationCount"] unsignedLongLongValue]==0,@"reserved diagnostic owner remains unused");
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
                                Check([Owner(final,@"probe")[@"allocationCount"] unsignedLongLongValue]==0,@"reserved diagnostic ownership unused");
                                NSString* log=[NSString stringWithContentsOfFile:final[@"diagnosticPath"] encoding:NSUTF8StringEncoding error:nil];
                                Check([log containsString:@"process_start"] && [log containsString:@"capacity_probe"],@"diagnostic events written");
                                MemoryProbe(final);
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
