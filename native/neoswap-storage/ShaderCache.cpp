// SPDX-License-Identifier: MIT
#include "ShaderCache.h"
#include <chrono>
#include <cstring>
#include <utility>
namespace neostation::storage {
namespace {
bool ready(std::future<Result>& future) {
    return future.valid() && future.wait_for(std::chrono::seconds(0)) == std::future_status::ready;
}
}
bool valid_spirv(const void* ptr, size_t bytes) noexcept {
    if (!ptr || bytes < 20 || bytes > 1024*1024 || bytes % 4) return false;
    uint32_t header[5]; std::memcpy(header, ptr, sizeof(header));
    return header[0]==0x07230203u && header[1]>=0x00010000u &&
        header[1]<=0x00010600u && header[3]!=0 && header[4]==0;
}
ShaderCache::ShaderCache(const std::string& path,uint64_t generation,Config config)
    :store_(path,config),generation_(generation),limit_(config.max_entries),max_blob_(config.max_blob) {}
bool ShaderCache::poll(Record& r,bool release_read) {
    if(ready(r.write)) {
        auto result=r.write.get();
        if(result.code!=Code::ok){r.failed=true;++stats_.write_failures;}
    }
    if(release_read && ready(r.read)) {
        auto result=r.read.get();
        if(result.code==Code::corrupt||result.code==Code::io||result.code==Code::missing){
            r.failed=true;++stats_.restore_failures;
        }
    }
    return !r.failed;
}
void ShaderCache::reclaim_failed() {
    for(auto it=records_.begin();it!=records_.end();) {
        if(!poll(it->second,true)){(void)store_.discard(it->second.handle);it=records_.erase(it);}
        else ++it;
    }
}
Result ShaderCache::acquire(const ShaderKey& key) {
    std::unique_lock lock(mutex_,std::try_to_lock);
    if(!lock.owns_lock()||!accepting())return {Code::busy,0,{}};
    ++stats_.lookups;
    auto it=records_.find(key);
    if(it==records_.end()){++stats_.misses;return {Code::missing,0,{}};}
    auto& r=it->second;r.stamp=++clock_;
    if(!poll(r,false)){++stats_.misses;return {Code::missing,0,{}};}
    Result result=store_.try_acquire(r.handle);
    if(result.code==Code::ok && valid_spirv(result.lease.data(),result.lease.size())){
        ++stats_.hits;return result;
    }
    if(ready(r.read)) {
        result=r.read.get();
        if(result.code==Code::ok && valid_spirv(result.lease.data(),result.lease.size())){
            ++stats_.hits;return result;
        }
        if(result.code==Code::corrupt||result.code==Code::io){
            r.failed=true;++stats_.restore_failures;
        }
    }
    if(!r.failed && !r.read.valid() && pressure_.load()==Pressure::normal) {
        auto request=store_.request(r.handle);
        if(request.code==Code::ok){r.read=std::move(request.completion);++stats_.restore_requests;}
    }
    ++stats_.misses;
    return {Code::busy,0,{}};
}
Code ShaderCache::publish(const ShaderKey& key,const uint32_t* words,size_t count) {
    if(count>max_blob_||!valid_spirv(words,count))return Code::invalid;
    if(pressure_.load()!=Pressure::normal)return Code::pressure;
    std::unique_lock lock(mutex_,std::try_to_lock);
    if(!lock.owns_lock()||!accepting())return Code::busy;
    if(count<16*1024){++stats_.tiny_refusals;return Code::invalid;}
    if(auto found=records_.find(key);found!=records_.end()) {
        if(poll(found->second,true)){++stats_.deduplicated;return Code::ok;}
        (void)store_.discard(found->second.handle);records_.erase(found);
    }
    if(records_.size()>=limit_){
        auto oldest=records_.begin();
        for(auto it=records_.begin();it!=records_.end();++it)
            if(it->second.stamp<oldest->second.stamp)oldest=it;
        (void)store_.discard(oldest->second.handle);records_.erase(oldest);
    }
    auto [it,inserted]=records_.try_emplace(key);(void)inserted;
    try {
        // One bounded snapshot. Core releases its vector only after admission.
        auto bytes=std::make_unique<Bytes>(count);std::memcpy(bytes->data(),words,count);
        auto request=store_.publish(bytes,Heat::cold);
        if(request.code!=Code::ok){records_.erase(it);++stats_.publish_rejections;return request.code;}
        it->second.handle=request.handle;it->second.write=std::move(request.completion);
        it->second.stamp=++clock_;++stats_.publications;stats_.admission_copy_bytes+=count;
        return Code::ok;
    }catch(...){records_.erase(it);++stats_.publish_rejections;return Code::busy;}
}
void ShaderCache::prefetch(const ShaderKey& key) {
    std::unique_lock lock(mutex_,std::try_to_lock);
    if(!lock.owns_lock()||!accepting())return;
    auto it=records_.find(key);if(it==records_.end())return;
    if(pressure_.load()!=Pressure::normal || !poll(it->second,true)||it->second.read.valid())return;
    auto q=store_.request(it->second.handle,true);
    if(q.code==Code::ok)it->second.read=std::move(q.completion);
}
void ShaderCache::invalidate(const ShaderKey& key) {
    std::unique_lock lock(mutex_,std::try_to_lock);
    if(!lock.owns_lock()){poisoned_.store(true);return;}
    auto it=records_.find(key);if(it==records_.end())return;
    it->second.failed=true;++stats_.invalidations;
}
void ShaderCache::event(uint32_t kind,uint64_t bytes) noexcept {
    if(kind==NS_STORAGE_SOURCE_COMPILE)++source_compiles_;
    else if(kind==NS_STORAGE_CACHED_MODULE_REJECTED)++rejected_modules_;
    else if(kind==NS_STORAGE_CPU_COPY_RELEASED)released_bytes_+=bytes;
}
void ShaderCache::pressure(Pressure value) noexcept { pressure_.store(value);store_.set_pressure(value); }
void ShaderCache::maintain(){std::lock_guard lock(mutex_);reclaim_failed();}
ShaderStats ShaderCache::snapshot(){std::lock_guard lock(mutex_);auto out=stats_;
    out.entries=records_.size();out.session=generation_;out.source_compiles=source_compiles_.load();
    out.cached_module_rejections=rejected_modules_.load();out.released_cpu_copy_bytes=released_bytes_.load();
    out.store=store_.snapshot();return out;
}
}
