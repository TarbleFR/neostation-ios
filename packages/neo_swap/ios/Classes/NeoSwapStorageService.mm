// SPDX-License-Identifier: MIT
#import "NeoSwapStorageService.h"
#import <UIKit/UIKit.h>
#include "Storage/ShaderCache.h"
#include "Storage/ShaderPolicy.h"
#include "Storage/SessionSlot.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <mutex>
#include <vector>
#include <sys/stat.h>

namespace {
using namespace neostation::storage;
constexpr uint64_t MiB=1024*1024;
NSString* const preferenceKey=@"NeoSwapShaderStorageEnabled.v1";
const char* const marker="NEOSTATION_STORAGE_SHADER_CACHE_V1";
struct State {
    dispatch_queue_t queue;
    dispatch_source_t timer=nullptr,pressureSource=nullptr;
    SessionSlot<ShaderCache> active;
    std::vector<std::shared_ptr<ShaderCache>> retired;
    std::atomic<uint64_t> requestedGeneration{1};
    std::atomic<int> binderResult{NS_STORAGE_DISABLED};
    std::mutex snapshotMutex;
    NSDictionary* cached=@{};
    NSDictionary* lastSessionCache=@{};
    NSString* title=@"";
    NSString* reason=@"disabled";
    NSString* lastFailure=@"";
    BOOL background=NO;
    NSProcessInfoThermalState thermal=NSProcessInfoThermalStateNominal;
    Pressure memoryPressure=Pressure::normal;
    uint64_t tick=0,started=0,stopped=0,setupFailures=0,retirementRefusals=0,warningEvents=0;
};
State& state() {
    static State* s=[] {
        auto* p=new State;
        p->retired.reserve(4);
        p->queue=dispatch_queue_create("neostation.storage.shader.utility",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_UTILITY,0));
        return p;
    }();
    return *s;
}
void applyPressure(State& s) {
    auto cache=s.active.control_load();if(!cache)return;
    cache->pause(s.background);
    const Pressure level=s.background ? Pressure::critical :
        s.thermal>=NSProcessInfoThermalStateSerious && s.memoryPressure==Pressure::normal ? Pressure::warning:s.memoryPressure;
    cache->pressure(level);
}
NSDictionary* statsDictionary(const ShaderStats& x) {
    const auto& d=x.store;
    return @{
      @"session":@(x.session),@"entries":@(x.entries),@"lookups":@(x.lookups),
      @"hits":@(x.hits),@"misses":@(x.misses),@"publications":@(x.publications),
      @"publishRefusals":@(x.publish_rejections),@"restoreRequests":@(x.restore_requests),
      @"restoreFailures":@(x.restore_failures),@"writeFailures":@(x.write_failures),
      @"sourceCompiles":@(x.source_compiles),@"cachedModuleRejections":@(x.cached_module_rejections),
      @"releasedCpuCopyBytesCumulative":@(x.released_cpu_copy_bytes),@"admissionCopyBytes":@(x.admission_copy_bytes),
      @"tinyRefusals":@(x.tiny_refusals),@"minimumCacheBytes":@16384,
      @"invalidations":@(x.invalidations),@"deduplicated":@(x.deduplicated),
      @"logicalBytes":@(d.logical_bytes),@"rawRamBytes":@(d.raw_ram_bytes),
      @"compressedCacheRamBytes":@(d.compressed_ram_bytes),@"pinnedRawBytes":@(d.pinned_raw_bytes),
      @"loadingReservedBytes":@(d.loading_reserved_bytes),@"managedRamPeakBytes":@(d.managed_ram_peak),
      @"diskOnlyLogicalBytes":@(d.disk_only_logical_bytes),@"storedPayloadBytes":@(d.stored_payload_bytes),
      @"allocatedFileBytes":@(d.allocated_file_bytes),@"fileHighWaterBytes":@(d.reserved_file_bytes),
      @"reusableFileBytes":@(d.reusable_file_bytes),@"reusedExtents":@(d.reused_extent_count),
      @"bytesRead":@(d.bytes_read),@"bytesWritten":@(d.bytes_written),
      @"readCalls":@(d.read_calls),@"writeCalls":@(d.write_calls),
      @"readP50Us":@(d.read_p50_us),@"readP95Us":@(d.read_p95_us),@"readP99Us":@(d.read_p99_us),
      @"readMaxUs":@(d.read_max_us),@"writeP95Us":@(d.write_p95_us),
      @"queueP95Us":@(d.queue_p95_us),@"restoreP95Us":@(d.restore_p95_us),
      @"evictedLogicalBytesCumulative":@(d.evicted_logical_bytes),@"restoredLogicalBytesCumulative":@(d.restored_logical_bytes),
      @"ramHits":@(d.ram_hits),@"warmHits":@(d.warm_hits),@"diskHits":@(d.disk_hits),
      @"prefetchUsed":@(d.prefetch_used),@"prefetchWasted":@(d.prefetch_wasted),@"prefetchCancelled":@(d.prefetch_cancelled),
      @"ioErrors":@(d.io_errors),@"corruptions":@(d.corruptions),@"lastErrno":@(d.last_errno),
      @"quotaRefusals":@(d.quota_refusals),@"backpressure":@(d.backpressure),
      @"pressure":@(static_cast<int>(d.pressure)),@"pressureEvents":@(d.pressure_events),
      @"compressionAttempts":@(d.compression_attempts),@"compressionAccepted":@(d.compression_accepted),
      @"compressionInputBytes":@(d.compression_input_bytes),@"compressionOutputBytes":@(d.compression_output_bytes),
      @"compressionUs":@(d.compression_us),@"decompressionUs":@(d.decompression_us),
      @"workerScratchPeakBytes":@(d.worker_scratch_peak),@"queuePeak":@(d.queue_peak)
    };
}
void snapshotOnQueue(State& s) {
    auto cache=s.active.control_load();
    NSMutableDictionary* result=[NSMutableDictionary dictionaryWithDictionary:@{
        @"abi":@1,@"marker":[NSString stringWithUTF8String:marker],
        @"active":@(cache && cache->accepting() && s.binderResult.load()==NS_STORAGE_OK &&
            cache->generation()==s.requestedGeneration.load()),
        @"title":s.title,@"reason":s.reason,@"lastFailure":s.lastFailure,
        @"binderResult":@(s.binderResult.load()),@"startedSessions":@(s.started),@"stoppedSessions":@(s.stopped),
        @"setupFailures":@(s.setupFailures),@"retirementRefusals":@(s.retirementRefusals),
        @"retiredSessions":@(s.retired.size()),@"warningEvents":@(s.warningEvents),
        @"background":@(s.background),@"thermal":@(s.thermal),
        @"ramBudgetBytes":@(8*MiB),@"warmBudgetIncludedBytes":@(MiB),@"diskBudgetBytes":@(128*MiB),
        @"writeRateBytesPerSecond":@(16*MiB),@"freeStorageFloorBytes":@(512*MiB),
        @"scope":@"regenerable Vulkan shader CPU bytecode; GPU modules, guest memory and JIT unchanged",
        @"onColdMiss":@"queue restore, recompile source without waiting for disk",
        @"physicalIPhoneValidated":@NO,@"gameplayGainValidated":@NO,@"kernelSwapEnabled":@NO,
        @"jetsamCause":NSNull.null,@"sampleTimestamp":@(NSDate.date.timeIntervalSince1970)
    }];
    result[@"lastSessionCache"]=s.lastSessionCache;
    if(cache) {
        result[@"cache"]=statsDictionary(cache->snapshot());
        if(!cache->accepting()&&!s.background)result[@"reason"]=@"cache_disabled_after_invalidation_contention";
    }
    auto metrics=sample_process();
    result[@"processResidentBytes"]=metrics.resident_valid?@(metrics.resident_bytes):NSNull.null;
    result[@"processFootprintBytes"]=metrics.footprint_valid?@(metrics.footprint_bytes):NSNull.null;
    result[@"processCompressedAccountedBytes"]=metrics.compressed_valid?@(metrics.compressed_accounted_bytes):NSNull.null;
    result[@"processAvailableBytes"]=metrics.process_available_valid?@(metrics.process_available_bytes):NSNull.null;
    uint64_t retiredRaw=0,retiredCompressed=0,retiredDisk=0;
    for(const auto& item:s.retired){auto old=item->snapshot().store;retiredRaw+=old.raw_ram_bytes;retiredCompressed+=old.compressed_ram_bytes;retiredDisk+=old.allocated_file_bytes;}
    result[@"retiredRawRamBytes"]=@(retiredRaw);result[@"retiredCompressedRamBytes"]=@(retiredCompressed);result[@"retiredDiskBytes"]=@(retiredDisk);
    std::lock_guard guard(s.snapshotMutex);s.cached=[result copy];
}
void reap(State& s) {
    // The service keeps the last owning reference. Destruction/join cannot run
    // on a Core callback when its temporary shared_ptr is released.
    for(auto it=s.retired.begin();it!=s.retired.end();) {
        if(it->use_count()==1)it=s.retired.erase(it);else ++it;
    }
}
void retireOnQueue(State& s) {
    if(auto old=s.active.exchange(nullptr)){
        s.lastSessionCache=statsDictionary(old->snapshot());
        old->pause(true);old->pressure(Pressure::critical);s.retired.push_back(std::move(old));++s.stopped;
    }
    reap(s);
}
std::shared_ptr<ShaderCache> current(uint64_t epoch) {
    auto& s=state();if(!epoch||s.binderResult.load()!=NS_STORAGE_OK||s.requestedGeneration.load()!=epoch)return {};
    auto cache=s.active.try_load();return cache&&cache->generation()==epoch&&cache->accepting()?cache:nullptr;
}
ShaderKey keyFrom(const uint8_t* key){ShaderKey k{};std::memcpy(k.data(),key,k.size());return k;}
uint64_t session() {
    auto& s=state();const auto epoch=s.requestedGeneration.load();auto cache=current(epoch);return cache?epoch:0;
}
int acquire(uint64_t epoch,const uint8_t* key,NeoSwapStorageView* out) {
    if(!out)return NS_STORAGE_INVALID;*out={};if(!key)return NS_STORAGE_INVALID;
    try{auto cache=current(epoch);if(!cache)return NS_STORAGE_DISABLED;auto r=cache->acquire(keyFrom(key));
        if(r.code!=Code::ok)return NS_STORAGE_MISS;
        auto lease=std::make_unique<Lease>(std::move(r.lease));out->words=reinterpret_cast<const uint32_t*>(lease->data());out->byte_count=lease->size();out->lease=lease.release();return NS_STORAGE_OK;
    }catch(...){return NS_STORAGE_MISS;}
}
int publish(uint64_t epoch,const uint8_t* key,const uint32_t* words,uint64_t bytes) {
    if(!key||!words||bytes>1024*1024)return NS_STORAGE_INVALID;
    try{auto cache=current(epoch);if(!cache)return NS_STORAGE_DISABLED;
        return cache->publish(keyFrom(key),words,static_cast<size_t>(bytes))==Code::ok?NS_STORAGE_OK:NS_STORAGE_BUSY;
    }catch(...){return NS_STORAGE_BUSY;}
}
void release(NeoSwapStorageView* out){if(out){delete static_cast<Lease*>(out->lease);*out={};}}
void prefetch(uint64_t epoch,const uint8_t* key){if(!key)return;try{if(auto cache=current(epoch))cache->prefetch(keyFrom(key));}catch(...) {}}
void invalidate(uint64_t epoch,const uint8_t* key){if(!key)return;try{if(auto cache=current(epoch))cache->invalidate(keyFrom(key));}catch(...) {}}
void event(uint64_t epoch,uint32_t kind,uint64_t bytes){try{if(auto cache=current(epoch))cache->event(kind,bytes);}catch(...) {}}
const NeoSwapStorageAPI api{sizeof(api),NEOSWAP_STORAGE_ABI,session,acquire,publish,release,prefetch,invalidate,event};
}

void NeoSwapStorage_Initialize(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        auto& s=state();
        s.timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,s.queue);
        if(!s.timer){s.reason=@"timer_unavailable";snapshotOnQueue(s);return;}
        dispatch_source_set_timer(s.timer,dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),250*NSEC_PER_MSEC,25*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(s.timer,^{@autoreleasepool {
            try{auto& stateRef=state();auto cache=stateRef.active.control_load();if(!cache&&stateRef.retired.empty())return;
                if(cache)cache->maintain();reap(stateRef);if(++stateRef.tick%4==0)snapshotOnQueue(stateRef);}
            catch(const std::exception& error){auto& stateRef=state();stateRef.lastFailure=[NSString stringWithUTF8String:error.what()]?:@"maintenance_error";}
        }});dispatch_resume(s.timer);
        s.pressureSource=dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE,0,
            DISPATCH_MEMORYPRESSURE_NORMAL|DISPATCH_MEMORYPRESSURE_WARN|DISPATCH_MEMORYPRESSURE_CRITICAL,s.queue);
        if(s.pressureSource){dispatch_source_set_event_handler(s.pressureSource,^{
            auto& x=state();const auto mask=dispatch_source_get_data(x.pressureSource);
            x.memoryPressure=mask&DISPATCH_MEMORYPRESSURE_CRITICAL?Pressure::critical:mask&DISPATCH_MEMORYPRESSURE_WARN?Pressure::warning:Pressure::normal;
            if(x.memoryPressure!=Pressure::normal)++x.warningEvents;applyPressure(x);
        });dispatch_resume(s.pressureSource);}
        dispatch_async(dispatch_get_main_queue(),^{
            const BOOL inactive=UIApplication.sharedApplication.applicationState==UIApplicationStateBackground;
            dispatch_async(state().queue,^{auto& x=state();x.background=inactive;x.thermal=NSProcessInfo.processInfo.thermalState;applyPressure(x);});
        });
        auto center=NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification* n){
            dispatch_async(state().queue,^{auto& x=state();x.background=YES;applyPressure(x);});}];
        [center addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(__unused NSNotification* n){
            dispatch_async(state().queue,^{auto& x=state();x.background=NO;applyPressure(x);});}];
        [center addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(__unused NSNotification* n){
            dispatch_async(state().queue,^{auto& x=state();++x.warningEvents;x.memoryPressure=Pressure::critical;applyPressure(x);});}];
        [center addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(__unused NSNotification* n){
            dispatch_async(state().queue,^{auto& x=state();x.thermal=NSProcessInfo.processInfo.thermalState;applyPressure(x);});}];
    });
}
const NeoSwapStorageAPI* NeoSwapStorage_GetAPI(uint32_t version){NeoSwapStorage_Initialize();return version==NEOSWAP_STORAGE_ABI?&api:nullptr;}
void NeoSwapStorage_SetBinderResult(int result){state().binderResult.store(result);}
BOOL NeoSwapStorage_GetPreference(void){return [NSUserDefaults.standardUserDefaults boolForKey:preferenceKey];}
void NeoSwapStorage_SetPreference(BOOL enabled){[NSUserDefaults.standardUserDefaults setBool:enabled forKey:preferenceKey];}
void NeoSwapStorage_BeginSession(NSString* title) {
    NeoSwapStorage_Initialize();auto& s=state();const uint64_t generation=s.requestedGeneration.fetch_add(1)+1;
    NSString* selected=[title copy]?:@"";const BOOL enabled=NeoSwapStorage_GetPreference();
    dispatch_async(s.queue,^{@autoreleasepool {
        auto& x=state();if(x.requestedGeneration.load()!=generation)return;
        retireOnQueue(x);x.title=selected;x.lastFailure=@"";
        if(!enabled){x.reason=@"disabled";snapshotOnQueue(x);return;}
        if(!shader_storage_title(selected.UTF8String?:"")){x.reason=@"unsupported_title";snapshotOnQueue(x);return;}
        if(x.retired.size()>=2){++x.retirementRefusals;x.reason=@"retired_sessions_busy";snapshotOnQueue(x);return;}
        if(x.background||!x.pressureSource){x.reason=@"background_or_pressure_monitor_unavailable";snapshotOnQueue(x);return;}
        try {
            auto manager=NSFileManager.defaultManager;
            NSURL* base=[manager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
            NSURL* directory=[base URLByAppendingPathComponent:@"NeoSwapShaderStorage-v1" isDirectory:YES];NSError* error=nil;
            if(!directory||![manager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700,NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:&error]){
                x.lastFailure=error.localizedDescription?:@"private_cache_directory_failed";++x.setupFailures;x.reason=@"filesystem_unavailable";snapshotOnQueue(x);return;
            }
            [directory setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nullptr];
            Config config;config.ram_bytes=8*MiB;config.warm_bytes=MiB;config.disk_bytes=128*MiB;
            config.max_entries=4096;config.compression_budget_us=500;
            auto cache=std::make_shared<ShaderCache>(directory.fileSystemRepresentation,generation,config);
            if(x.requestedGeneration.load()!=generation)return;
            (void)x.active.exchange(std::move(cache));++x.started;x.reason=@"ready";applyPressure(x);snapshotOnQueue(x);
        }catch(const std::exception& error){++x.setupFailures;x.reason=@"setup_failed";x.lastFailure=[NSString stringWithUTF8String:error.what()]?:@"unknown";snapshotOnQueue(x);}
    }});
}
void NeoSwapStorage_EndSession(void) {
    auto& s=state();const uint64_t generation=s.requestedGeneration.fetch_add(1)+1;
    dispatch_async(s.queue,^{auto& x=state();if(x.requestedGeneration.load()!=generation)return;retireOnQueue(x);x.reason=@"session_ended";snapshotOnQueue(x);});
}
NSDictionary* NeoSwapStorage_Diagnostics(void) {
    NeoSwapStorage_Initialize();auto& s=state();NSMutableDictionary* result;
    {std::lock_guard guard(s.snapshotMutex);result=[s.cached mutableCopy];}
    result[@"requestedEnabled"]=@(NeoSwapStorage_GetPreference());result[@"appliesOnNextLaunch"]=@YES;
    return result;
}
