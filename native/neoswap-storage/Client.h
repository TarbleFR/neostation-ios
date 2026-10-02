// SPDX-License-Identifier: MIT
#pragma once
#include "StorageABI.h"
#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <vector>
namespace neostation::storage_client {
inline constinit std::atomic<const NeoSwapStorageAPI*> installed{nullptr};
inline int install(const NeoSwapStorageAPI* api) noexcept {
    if(!api||api->struct_size!=sizeof(*api)||api->abi_version!=NEOSWAP_STORAGE_ABI||
       !api->session||!api->acquire||!api->publish||!api->release||!api->prefetch||
       !api->invalidate||!api->event)return NS_STORAGE_INVALID;
    const NeoSwapStorageAPI* expected=nullptr;
    return installed.compare_exchange_strong(expected,api)||expected==api?NS_STORAGE_OK:NS_STORAGE_INVALID;
}
struct Ticket {const NeoSwapStorageAPI* api=nullptr;uint64_t session=0;std::array<uint8_t,32> key{};};
inline Ticket ticket() noexcept {Ticket t;t.api=installed.load();if(t.api)t.session=t.api->session();return t;}
inline bool active(const Ticket& t) noexcept {return t.api&&t.session&&t.api->session()==t.session;}
class Lease final {
public:
    explicit Lease(const Ticket& t):api_(t.api){
        if(active(t)&&api_->acquire(t.session,t.key.data(),&view_)==NS_STORAGE_OK){
            uint32_t h[5]{};
            if(view_.words&&view_.lease&&view_.byte_count>=sizeof(h)&&view_.byte_count<=1024*1024&&view_.byte_count%4==0){
                std::memcpy(h,view_.words,sizeof(h));valid_=h[0]==0x07230203u&&h[1]>=0x00010000u&&h[1]<=0x00010600u&&h[3]&&h[4]==0;
            }
            if(!valid_){api_->invalidate(t.session,t.key.data());reset();}
        }else reset();
    }
    ~Lease(){reset();}
    Lease(const Lease&)=delete;Lease& operator=(const Lease&)=delete;
    explicit operator bool()const noexcept{return valid_;}
    const uint32_t* data()const noexcept{return view_.words;}
    size_t size()const noexcept{return static_cast<size_t>(view_.byte_count);}
    void reset() noexcept {if(api_&&view_.lease)api_->release(&view_);view_={};valid_=false;}
private:const NeoSwapStorageAPI* api_;NeoSwapStorageView view_{};bool valid_=false;
};
enum class CompileResult {ok, source_failure, module_failure};
enum class ModuleResult {ok, retry_source, fatal};
// Actual production hook: cache bytes are consumed by vkCreateShaderModule,
// NOT a debug-only getter. Driver objects and live GPU memory are never evicted.
// Build and Create must preserve the original compiler and module parameters.
template<class Build,class Create>
CompileResult compile(const Ticket& t,std::vector<uint32_t>& original,Build&& build,Create&& create){
    {
        Lease cached(t);
        if(cached){
            const auto result=create(cached.data(),cached.size());
            if(result==ModuleResult::ok){
                std::vector<uint32_t>().swap(original);return CompileResult::ok;
            }
            // Out-of-memory/device-loss must not allocate another compiler
            // result. Only an explicit invalid-cache result permits one rebuild.
            if(result==ModuleResult::fatal)return CompileResult::module_failure;
            t.api->invalidate(t.session,t.key.data());
            t.api->event(t.session,NS_STORAGE_CACHED_MODULE_REJECTED,cached.size());
        }
    } // release pin before rebuilding; no stale cache error blocks original path
    if(active(t))t.api->event(t.session,NS_STORAGE_SOURCE_COMPILE,0);
    if(!build(original))return CompileResult::source_failure;
    if(create(original.data(),original.size()*sizeof(uint32_t))!=ModuleResult::ok)return CompileResult::module_failure;
    if(active(t)&&t.api->publish(t.session,t.key.data(),original.data(),original.size()*4)==NS_STORAGE_OK){
        const auto bytes=original.capacity()*sizeof(uint32_t);
        std::vector<uint32_t>().swap(original);
        t.api->event(t.session,NS_STORAGE_CPU_COPY_RELEASED,bytes);
    }
    return CompileResult::ok;
}
}
