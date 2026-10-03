// SPDX-License-Identifier: MIT
// Production UIKit service in an iOS simulator app, not RPCS3 gameplay.
#import <UIKit/UIKit.h>
#import "NeoSwapStorageService.h"
#include "SourceClient.h"
#include "FrameClient.h"
#include <chrono>
#include <cstring>
#include <thread>
#include <vector>
#include <stdexcept>
using namespace std::chrono_literals;
static void require(bool b,const char* m){if(!b)throw std::runtime_error(m);}
template<class F> static bool until(F f,int seconds=15){for(int i=0;i<seconds*100;++i){if(f())return true;std::this_thread::sleep_for(10ms);}return false;}
static void runTest(){@autoreleasepool {
    NSMutableDictionary* result=[@{@"passed":@NO,@"physicalIPhoneValidated":@NO,@"realRPCS3GameplayValidated":@NO} mutableCopy];
    try{
        const auto* api=NeoSwapStorage_GetAPI(1);require(api!=nullptr,"ABI unavailable");NeoSwapStorage_SetBinderResult(NS_STORAGE_OK);
        const auto* sourceApi=NeoSwapStorage_GetSourceAPI(1);require(sourceApi!=nullptr,"source ABI unavailable");
        require(NeoSwapStorage_GetSourceAPI(2)==nullptr,"wrong source ABI accepted");
        NeoSwapStorage_SetSourceBinderResult(NS_SOURCE_OK);
        require(neostation::source_client::install(sourceApi)==NS_SOURCE_OK,"source client binding");
        NeoSwapStorage_SetPreference(NO);NeoSwapStorage_BeginSession(@"BCES00510");
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"reason"] isEqual:@"disabled"];}),"default-off session");require(api->session()==0,"disabled epoch");
        require(sourceApi->session()==0,"disabled source epoch");
        NeoSwapStorage_SetPreference(YES);NeoSwapStorage_BeginSession(@"BLES00113");
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"reason"] isEqual:@"unsupported_title"];}),"title restriction");require(api->session()==0,"unsupported epoch");
        require(sourceApi->session()==0,"unsupported source epoch");
        NeoSwapStorage_BeginSession(@"BCES00510");require(until([&]{return api->session()!=0;}),"enabled setup");
        const uint64_t epoch=api->session();std::vector<uint32_t> words(256*1024,0x10101);
        require(until([&]{return sourceApi->session()==epoch;}),"source epoch setup");
        std::string text(128*1024,' ');uint32_t textRandom=301;
        for(auto& byte:text){textRandom^=textRandom<<13;textRandom^=textRandom>>17;textRandom^=textRandom<<5;byte=static_cast<char>(textRandom);}
        const auto originalText=text;neostation::source_client::ColdSource sourceOwner;
        require(until([&]{return sourceOwner.offload(text,1);}),"source admission");require(text.empty(),"Core source allocation retained");
        require(until([&]{NSDictionary* d=NeoSwapStorage_Diagnostics()[@"sourceArchive"];
            return [d[@"archivedSourceBytesCumulative"] unsignedLongLongValue]==originalText.size() &&
                [d[@"stagingRamBytes"] unsignedLongLongValue]==0;}),"source verified eviction");
        std::string restoredText;int sourceError=0;
        require(sourceOwner.restore(restoredText,sourceError)==NS_SOURCE_OK && restoredText==originalText,"source private file roundtrip");
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"sourceArchive"][@"sourceReads"] unsignedLongLongValue]>0;}),"source read diagnostics");
        result[@"sourceDiagnostics"]=NeoSwapStorage_Diagnostics()[@"sourceArchive"];
        std::string pixels(1280*720*3/2,'\0');uint32_t pixelRandom=779;
        for(auto& byte:pixels){pixelRandom^=pixelRandom<<13;pixelRandom^=pixelRandom>>17;pixelRandom^=pixelRandom<<5;byte=static_cast<char>(pixelRandom);}
        const auto originalPixels=pixels;neostation::source_client::ColdFrame pixelOwner;
        require(until([&]{return pixelOwner.offload(pixels.data(),pixels.size());}),"pixel domain admission");
        require(pixels==originalPixels,"pixel client changed caller allocation before transfer");std::string().swap(pixels);
        require(until([&]{NSDictionary* d=NeoSwapStorage_Diagnostics()[@"sourceArchive"];
            return [d[@"videoPixelLiveArchivedBytes"] unsignedLongLongValue]==originalPixels.size() &&
                [d[@"stagingRamBytes"] unsignedLongLongValue]==0;}),"pixel verified checkpoint");
        std::string restoredPixels;int pixelError=0;
        require(pixelOwner.restore(restoredPixels,pixelError)==NS_SOURCE_OK && restoredPixels==originalPixels,"pixel real private-file roundtrip");
        // Diagnostics are a utility-queue snapshot, refreshed once per second.
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"sourceArchive"][@"videoPixelReturnedArchiveBytesCumulative"] unsignedLongLongValue]>=originalPixels.size();}),"pixel read diagnostics");
        result[@"pixelDiagnostics"]=NeoSwapStorage_Diagnostics()[@"sourceArchive"];
        words[0]=0x07230203;words[1]=0x00010500;words[3]=64;words[4]=0;
        for(unsigned i=1;i<=16;++i){uint8_t key[32]{};key[0]=i;uint32_t random=i;
            for(size_t n=5;n<words.size();++n){random^=random<<13;random^=random>>17;random^=random<<5;words[n]=random;}words[5]=i;
            require(until([&]{return api->publish(epoch,key,words.data(),words.size()*4)==NS_STORAGE_OK;}),"bounded publication");}
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"cache"][@"diskOnlyLogicalBytes"] unsignedLongLongValue]>0;}),"disk-only eviction");
        uint8_t key[32]{};key[0]=1;NeoSwapStorageView view{};
        require(until([&]{return api->acquire(epoch,key,&view)==NS_STORAGE_OK;}),"real file restoration");require(view.byte_count==words.size()*4&&view.words[5]==1,"restored identity");
        NeoSwapStorage_EndSession();require(api->session()==0,"immediate epoch invalidation");
        require(sourceApi->session()==0,"immediate source invalidation");
        require(sourceOwner.restore(restoredText,sourceError)==NS_SOURCE_DISABLED && restoredText.empty(),"stale source read accepted");sourceOwner.reset();
        require(pixelOwner.restore(restoredPixels,pixelError)==NS_SOURCE_DISABLED && restoredPixels.empty(),"stale pixel read accepted");pixelOwner.reset();
        NeoSwapStorageView stale{};require(api->acquire(epoch,key,&stale)==NS_STORAGE_DISABLED,"stale request accepted");
        std::this_thread::sleep_for(300ms);require(view.words[5]==1,"lease lost after shutdown");api->release(&view);
        NeoSwapStorage_BeginSession(@"BCES00510");require(until([&]{return api->session()!=0&&api->session()!=epoch;}),"restart");
        const uint64_t next=api->session();require(api->acquire(epoch,key,&stale)==NS_STORAGE_DISABLED,"old generation leaked");
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
        require(until([&]{return api->session()==0;}),"background pause");
        require(sourceApi->session()==0,"source background pause");
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillEnterForegroundNotification object:nil];
        require(until([&]{return api->session()==next;}),"foreground resume");
        require(until([&]{return sourceApi->session()==next;}),"source foreground resume");
        [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidReceiveMemoryWarningNotification object:nil];
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"cache"][@"pressure"] intValue]==2;}),"pressure propagation");
        require(api->publish(next,key,words.data(),words.size()*4)!=NS_STORAGE_OK,"optional publication under pressure");
        text=originalText;neostation::source_client::ColdSource pressureRefusal;
        require(!pressureRefusal.offload(text,0) && text==originalText,"source pressure refusal loses original");
        pixels=originalPixels;neostation::source_client::ColdFrame pixelPressureRefusal;
        require(!pixelPressureRefusal.offload(pixels.data(),pixels.size())&&pixels==originalPixels,"pixel pressure refusal loses original");
        NeoSwapStorage_EndSession();NeoSwapStorage_SetPreference(NO);
        require(until([&]{return [NeoSwapStorage_Diagnostics()[@"reason"] isEqual:@"session_ended"];}),"end diagnostics");
        result[@"passed"]=@YES;result[@"realIOSSimulatorServiceExecuted"]=@YES;
        result[@"privateFileRoundTrip"]=@YES;result[@"epochIsolation"]=@YES;result[@"leaseSurvivedSessionEnd"]=@YES;
        result[@"lifecycleNotificationsInjected"]=@YES;result[@"pressureNotificationInjected"]=@YES;
        result[@"sourceArchiveRoundTrip"]=@YES;result[@"sourceEpochIsolation"]=@YES;result[@"sourcePressureRefusal"]=@YES;
        result[@"videoPixelRoundTrip"]=@YES;result[@"videoPixelEpochIsolation"]=@YES;result[@"videoPixelPressureRefusal"]=@YES;
        result[@"diagnostics"]=NeoSwapStorage_Diagnostics();
    }catch(const std::exception& e){result[@"error"]=[NSString stringWithUTF8String:e.what()];}
    NSString* path=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"shader-service-runtime.json"];
    NSData* data=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:path atomically:YES];
}}
@interface StorageTestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation StorageTestDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    (void)app;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{runTest();});return YES;
}
@end
int main(int argc,char** argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(StorageTestDelegate.class));}}
