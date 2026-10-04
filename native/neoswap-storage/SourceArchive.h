// SPDX-License-Identifier: MIT
#pragma once
#include "ManagedSwap.h"
#include "SourceABI.h"
#include <atomic>
#include <array>
#include <map>
#include <mutex>
namespace neostation::source_archive {
struct Config {
    managed_swap::Config managed;
    uint64_t staging_bytes=4ULL<<20;
    uint32_t max_sources=4096,max_pending=64,minimum_bytes=4096;
    // The GLSL-only default is retained. VDEC opts into domain 3 explicitly.
    uint32_t domain_mask=7;
    Config();
};
struct Admission { int code=NS_SOURCE_BUSY;uint64_t object=0; };
enum class Operation { admitted, quota_refused, discarded, checkpoint, archived, retry,
    archive_failed, ram_read, restored_chunk, restored, restore_failed, pressure };
const char* operation_name(Operation) noexcept;
const char* result_name(Operation,int result) noexcept;
struct OperationEvent {
    uint64_t sequence=0,monotonic_us=0,session=0,object=0,bytes=0,duration_us=0;
    uint32_t domain=0,chunk=0;
    int result=0,os_error=0;
    Operation operation=Operation::admitted;
};
struct OperationBatch {
    static constexpr size_t capacity=64;
    std::array<OperationEvent,capacity> events{};
    size_t count=0;
    uint64_t dropped=0,pending=0;
};
struct Stats {
    uint64_t session=0,sources=0,pending=0,staging_bytes=0,staging_peak=0;
    uint64_t admissions=0,refusals=0,archived_bytes=0,archive_failures=0;
    uint64_t reads=0,restored_bytes=0,read_failures=0,core_released_capacity=0;
    uint64_t pixel_admissions=0,pixel_archived_bytes=0,pixel_restored_bytes=0;
    uint64_t pixel_live_archived_bytes=0;
    uint64_t transient_retries=0;
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
    // Core demand may use a complete immutable RAM snapshot immediately.
    // Busy means utility I/O is needed (or the bounded try-lock lost); no I/O.
    int try_read_staging(uint64_t object,char* output,size_t exact_bytes);
    int read(uint64_t object,char* output,size_t exact_bytes,int& os_error);
    void discard(uint64_t object) noexcept;
    void released(uint64_t capacity) noexcept { released_.fetch_add(capacity); }
    // A host quantum bounds completed chunks/retirements. True asks for a
    // continuation at the END of the utility queue, never a producer retry.
    bool maintain(uint32_t chunk_limit=UINT32_MAX,uint32_t retirement_limit=UINT32_MAX);
    void pressure(storage::Pressure value);
    void pause(bool value) noexcept { paused_.store(value); }
    bool accepting() const noexcept {return !paused_.load() && pressure_.load()==storage::Pressure::normal;}
    uint64_t generation() const noexcept {return session_;}
    Stats snapshot();
    // The journal has a fixed RAM bound. Core callbacks append while holding
    // the existing admission lock; only a utility worker drains/writes it.
    OperationBatch drain_operations();
#ifdef NEOSWAP_STORAGE_TESTING
    void inject(storage::Store::Fault fault){manager_.inject(fault);}
    void defer_after_chunks(uint32_t count){defer_after_chunks_=count;}
#endif
private:
    struct Record {
        uint64_t id=0;size_t bytes=0;
        std::shared_ptr<storage::Bytes> staging;
        managed_swap::Object object{};
        uint32_t next_chunk=0,chunks=0;
        uint64_t chunk_generation=0;
        bool chunk_written=false;
        bool working=false,retired=false,failed=false;
        uint32_t domain=0;
    };
    const Config config_;
    const uint64_t session_;
    managed_swap::Manager manager_;
    std::mutex mutex_;
    std::map<uint64_t,std::shared_ptr<Record>> records_;
    uint64_t next_id_=1,staging_=0,pending_=0;
    Stats stats_;
    std::array<OperationEvent,512> operations_{};
    size_t operation_head_=0,operation_count_=0;
    uint64_t operation_sequence_=0,operation_dropped_=0;
    void record_locked(Operation,uint64_t object,uint32_t domain,uint64_t bytes,
        uint64_t duration=0,int result=0,int error=0,uint32_t chunk=UINT32_MAX) noexcept;
    std::atomic<bool> paused_{false};
    std::atomic<storage::Pressure> pressure_{storage::Pressure::normal};
    std::atomic<uint64_t> released_{0};
#ifdef NEOSWAP_STORAGE_TESTING
    uint32_t defer_after_chunks_=0;
#endif
};
}
