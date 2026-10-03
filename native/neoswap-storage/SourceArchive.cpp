// SPDX-License-Identifier: MIT
#include "SourceArchive.h"
#include <algorithm>
#include <chrono>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <unistd.h>
namespace neostation::source_archive {
namespace {
int translate(managed_swap::Code code){
    using managed_swap::Code;
    switch(code){
    case Code::ok:return NS_SOURCE_OK;
    case Code::busy:return NS_SOURCE_BUSY;
    case Code::pressure:return NS_SOURCE_PRESSURE;
    case Code::quota:return NS_SOURCE_QUOTA;
    case Code::missing:case Code::stale:return NS_SOURCE_MISSING;
    case Code::invalid:return NS_SOURCE_INVALID;
    case Code::stopped:return NS_SOURCE_DISABLED;
    case Code::io:case Code::corrupt:return NS_SOURCE_IO;
    }
    return NS_SOURCE_INVALID;
}
uint64_t mapped(size_t bytes){const auto page=static_cast<uint64_t>(sysconf(_SC_PAGESIZE));return ((bytes+page-1)/page)*page;}
template<class Operation> managed_swap::Result retry(Operation&& operation){
    const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(20);
    for(;;){auto result=operation();
        if(result.code!=managed_swap::Code::busy || std::chrono::steady_clock::now()>=deadline)return result;
        std::this_thread::sleep_for(std::chrono::microseconds(50));
    }
}
}
Config::Config(){
    managed.chunk_bytes=65536;managed.resident_bytes=8ULL<<20;
    managed.logical_bytes=128ULL<<20;managed.max_objects=4096;
    managed.store.max_blob=65536;managed.store.max_entries=4096;
    managed.store.ram_bytes=1ULL<<20;managed.store.warm_bytes=0;
    managed.store.disk_bytes=128ULL<<20;managed.store.compression=true;
    managed.store.compression_budget_us=500;
}
Archive::Archive(const std::string& directory,uint64_t session,Config config)
    :config_(config),session_(session),manager_(directory,config.managed){
    if(!session || !config.max_sources || config.max_sources>4096 || !config.max_pending ||
       config.minimum_bytes<4096 || config.minimum_bytes>NEOSWAP_SOURCE_MAX_BYTES ||
       !config.domain_mask || (config.domain_mask & ~15u) ||
       config.staging_bytes<NEOSWAP_SOURCE_MAX_BYTES || config.staging_bytes>(16ULL<<20))
        throw std::invalid_argument("source archive limits");
}
Admission Archive::admit(uint32_t domain,const char* source,size_t bytes){
    if(!source || domain>3 || !(config_.domain_mask & (1u<<domain)) || bytes<config_.minimum_bytes || bytes>NEOSWAP_SOURCE_MAX_BYTES)
        return {NS_SOURCE_INVALID,0};
    if(!accepting())return {NS_SOURCE_PRESSURE,0};
    std::unique_lock lock(mutex_,std::try_to_lock);if(!lock.owns_lock())return {};
    const auto charge=mapped(bytes);
    if(!next_id_ || records_.size()>=config_.max_sources || pending_>=config_.max_pending ||
       staging_>config_.staging_bytes || charge>config_.staging_bytes-staging_){
        ++stats_.refusals;return {NS_SOURCE_QUOTA,0};
    }
    try {
        auto record=std::make_shared<Record>();record->id=next_id_++;record->bytes=bytes;
        record->domain=domain;
        record->staging=std::make_shared<storage::Bytes>(bytes);
        std::memcpy(record->staging->data(),source,bytes);
        if(!records_.emplace(record->id,record).second){++stats_.refusals;return {};}
        staging_+=charge;++pending_;
        stats_.staging_peak=std::max(stats_.staging_peak,staging_);++stats_.admissions;
        if(domain==3)++stats_.pixel_admissions;
        return {NS_SOURCE_OK,record->id};
    }catch(...){++stats_.refusals;return {};}
}
void Archive::discard(uint64_t object) noexcept {
    // Core destructors enqueue this control operation in the host wrapper;
    // they never wait here or join the storage worker.
    std::lock_guard lock(mutex_);
    auto it=records_.find(object);if(it!=records_.end())it->second->retired=true;
}
void Archive::maintain(){
    std::shared_ptr<Record> record;
    {
        std::lock_guard lock(mutex_);
        for(auto it=records_.begin();it!=records_.end();){
            auto& r=*it->second;
            if(r.retired && !r.working){
                if(r.object.id)(void)manager_.destroy(r.object);
                if(r.staging){staging_-=r.staging->mapped_size();--pending_;}
                it=records_.erase(it);continue;
            }
            if(!record && r.staging && !r.failed && !r.working && accepting()){
                record=it->second;r.working=true;
            }
            ++it;
        }
    }
    if(!record)return;
    managed_swap::Result result{};
    try {
        if(!record->object.id){
            auto created=manager_.create(record->bytes);result={created.code,created.os_error};
            record->object=created.object;record->chunks=created.chunks;
        }
        for(;result.code==managed_swap::Code::ok && record->next_chunk<record->chunks;){
            const auto index=record->next_chunk;
            if(!record->chunk_written){
                auto info=manager_.describe(record->object,index);
                if(info.code!=managed_swap::Code::ok){result={info.code,info.os_error};break;}
                auto write=manager_.write_chunk(record->object,index,info.generation);
                result={write.code,write.os_error};if(result.code!=managed_swap::Code::ok)break;
                const auto offset=static_cast<size_t>(index)*config_.managed.chunk_bytes;
                std::memcpy(write.lease.data(),record->staging->data()+offset,write.lease.size());
                record->chunk_generation=write.lease.generation();record->chunk_written=true;
            }
            result=retry([&]{return manager_.checkpoint_chunk(record->object,index,record->chunk_generation);});
            if(result.code==managed_swap::Code::ok)result=retry([&]{return manager_.evict_chunk(record->object,index);});
            if(result.code==managed_swap::Code::ok){
                ++record->next_chunk;record->chunk_written=false;
#ifdef NEOSWAP_STORAGE_TESTING
                if(defer_after_chunks_==record->next_chunk){
                    defer_after_chunks_=0;result={managed_swap::Code::busy,0};break;
                }
#endif
            }
        }
    }catch(...){result={managed_swap::Code::busy,0};}
    const bool transient=result.code==managed_swap::Code::busy || result.code==managed_swap::Code::pressure;
    if(result.code!=managed_swap::Code::ok && !transient && record->object.id){
        (void)manager_.destroy(record->object);record->object={};
    }
    std::lock_guard lock(mutex_);record->working=false;
    if(result.code==managed_swap::Code::ok){
        // All chunks have a synchronized, verified disk version. Only now
        // release the original accepted CPU snapshot, not merely its pointer.
        const auto charge=record->staging->mapped_size();record->staging.reset();
        staging_-=charge;--pending_;stats_.archived_bytes+=record->bytes;
        if(record->domain==3)stats_.pixel_archived_bytes+=record->bytes;
    }else if(transient){
        // Rate limiting, contention or a pressure transition is not corruption.
        // Preserve both the COMPLETE snapshot and verified chunk progress.
        // Restarting from chunk zero could starve under a write-rate limit.
        // Resume on the NEXT utility tick, never
        // sleep/retry on a producer/render thread or disable it permanently.
        ++stats_.transient_retries;
    }else{
        record->failed=true;++stats_.archive_failures;stats_.last_errno=result.os_error;
        // Keep the complete original snapshot readable on EVERY refusal/error.
    }
}
int Archive::read(uint64_t object,char* output,size_t bytes,int& os_error){
    os_error=0;std::shared_ptr<Record> record;
    {
        std::lock_guard lock(mutex_);auto it=records_.find(object);
        if(it==records_.end() || it->second->retired)return NS_SOURCE_MISSING;
        record=it->second;if(!output || bytes!=record->bytes)return NS_SOURCE_INVALID;
        ++stats_.reads;
        if(record->staging){std::memcpy(output,record->staging->data(),bytes);return NS_SOURCE_OK;}
    }
    managed_swap::Result result{};
    for(uint32_t index=0;static_cast<uint64_t>(index)*config_.managed.chunk_bytes<bytes;++index){
        auto read=manager_.read_chunk(record->object,index);result={read.code,read.os_error};
        if(result.code!=managed_swap::Code::ok)break;
        const auto offset=static_cast<size_t>(index)*config_.managed.chunk_bytes;
        if(read.lease.size()!=std::min<size_t>(config_.managed.chunk_bytes,bytes-offset)){
            result={managed_swap::Code::corrupt,0};break;
        }
        std::memcpy(output+offset,read.lease.data(),read.lease.size());
    }
    std::lock_guard lock(mutex_);
    if(result.code==managed_swap::Code::ok){stats_.restored_bytes+=bytes;
        if(record->domain==3)stats_.pixel_restored_bytes+=bytes;}
    else{++stats_.read_failures;stats_.last_errno=result.os_error;os_error=result.os_error;}
    return translate(result.code);
}
void Archive::pressure(storage::Pressure value){pressure_.store(value);manager_.set_pressure(value);}
Stats Archive::snapshot(){std::lock_guard lock(mutex_);auto out=stats_;
    out.session=session_;out.sources=records_.size();out.pending=pending_;
    for(const auto& [id,r]:records_){(void)id;
        if(r->domain==3 && !r->staging && !r->retired)out.pixel_live_archived_bytes+=r->bytes;}
    out.staging_bytes=staging_;out.core_released_capacity=released_.load();
    out.managed=manager_.snapshot();return out;
}
}
