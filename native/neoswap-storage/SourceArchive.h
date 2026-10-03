// SPDX-License-Identifier: MIT
#pragma once
#include "ManagedSwap.h"
#include "SourceABI.h"
#include <atomic>
#include <map>
#include <mutex>
namespace neostation::source_archive {
struct Config {
    managed_swap::Config managed;
    uint64_t staging_bytes=4ULL<<20;
    uint32_t max_sources=4096,max_pending=64,minimum_bytes=4096;
    Config();
};
struct Admission { int code=NS_SOURCE_BUSY;uint64_t object=0; };
struct Stats {
    uint64_t session=0,sources=0,pending=0,staging_bytes=0,staging_peak=0;
    uint64_t admissions=0,refusals=0,archived_bytes=0,archive_failures=0;
    uint64_t reads=0,restored_bytes=0,read_failures=0,core_released_capacity=0;
    int last_errno=0;
    managed_swap::Stats managed;
};
// Construction, maintenance, demand read and destruction are utility-only.
// Only admission runs on Core callers: bounded try-lock, no disk I/O.
// Retirement is deferred to the same utility queue as maintenance/read.
class Archive final {
public:
    Archive(const std::string& directory,uint64_t session,Config config={});
    Admission admit(uint32_t domain,const char* source,size_t bytes);
    int read(uint64_t object,char* output,size_t exact_bytes,int& os_error);
    void discard(uint64_t object) noexcept;
    void released(uint64_t capacity) noexcept { released_.fetch_add(capacity); }
    void maintain();
    void pressure(storage::Pressure value);
    void pause(bool value) noexcept { paused_.store(value); }
    bool accepting() const noexcept {return !paused_.load() && pressure_.load()==storage::Pressure::normal;}
    uint64_t generation() const noexcept {return session_;}
    Stats snapshot();
#ifdef NEOSWAP_STORAGE_TESTING
    void inject(storage::Store::Fault fault){manager_.inject(fault);}
#endif
private:
    struct Record {
        uint64_t id=0;size_t bytes=0;
        std::shared_ptr<storage::Bytes> staging;
        managed_swap::Object object{};
        bool working=false,retired=false,failed=false;
    };
    const Config config_;
    const uint64_t session_;
    managed_swap::Manager manager_;
    std::mutex mutex_;
    std::map<uint64_t,std::shared_ptr<Record>> records_;
    uint64_t next_id_=1,staging_=0,pending_=0;
    Stats stats_;
    std::atomic<bool> paused_{false};
    std::atomic<storage::Pressure> pressure_{storage::Pressure::normal};
    std::atomic<uint64_t> released_{0};
};
}
