// SPDX-License-Identifier: MIT
#pragma once
#include <algorithm>
#include <array>
#include <atomic>
#include <cstdint>
#include <mutex>
#include <vector>

// Host-only scheduling. Core's source ABI and its allocation policy are unchanged.
namespace neostation::source_work {
struct Discard { uint64_t epoch=0,object=0; };
class Queue final {
public:
    static constexpr size_t discard_quantum=64;
    struct Batch { std::array<Discard,discard_quantum> discards{};size_t count=0; };
    bool request() {
        std::lock_guard lock(mutex_);requested_=true;
        if(scheduled_){++coalesced_;return false;}
        scheduled_=true;return true;
    }
    bool discard(uint64_t epoch,uint64_t object) {
        std::lock_guard lock(mutex_);discards_.push_back({epoch,object});requested_=true;
        if(scheduled_){++coalesced_;return false;}
        scheduled_=true;return true;
    }
    Batch begin() {
        std::lock_guard lock(mutex_);Batch out;requested_=false;++quanta_;
        while(!discards_.empty() && out.count<discard_quantum){
            out.discards[out.count++]=discards_.back();discards_.pop_back();
        }
        return out;
    }
    // A continuation goes to the tail of the utility FIFO. A pending demand
    // cancels this continuation; its completion (or the timer) re-arms it.
    bool finish(bool more) {
        std::lock_guard lock(mutex_);requested_=requested_||more;
        if(demands_.load()){scheduled_=false;return false;}
        if(requested_||!discards_.empty())return true;
        scheduled_=false;return false;
    }
    void defer() {std::lock_guard lock(mutex_);requested_=true;scheduled_=false;}
    void demand_begin() noexcept {demands_.fetch_add(1);}
    bool demand_end() noexcept {return demands_.fetch_sub(1)==1;}
    bool resume() {
        std::lock_guard lock(mutex_);
        if(scheduled_||(!requested_&&discards_.empty()))return false;
        scheduled_=true;return true;
    }
    bool demand_pending() const noexcept {return demands_.load()!=0;}
    uint64_t coalesced() {std::lock_guard lock(mutex_);return coalesced_;}
    uint64_t quanta() {std::lock_guard lock(mutex_);return quanta_;}
    size_t pending_discards() {std::lock_guard lock(mutex_);return discards_.size();}
private:
    std::mutex mutex_;
    std::vector<Discard> discards_;
    bool requested_=false,scheduled_=false;
    uint64_t coalesced_=0,quanta_=0;
    std::atomic<uint32_t> demands_{0};
};
class VideoMemoryNeed final {
public:
    static constexpr uint64_t enter_bytes=1ULL<<30,leave_bytes=3ULL<<29;
    // budget_shrink: the global NeoSwap budget controller measured system room
    // below its operational reserve. Archive cold video early, before the
    // process headroom alone would ask for it; it never invents a valid margin.
    void update(uint64_t available,bool valid,bool warned,uint64_t physical=0,bool budget_shrink=false) noexcept {
        enter_=physical?std::clamp<uint64_t>(physical/8,1ULL<<29,enter_bytes):enter_bytes;
        leave_=enter_+enter_/2;
        if(!valid){needed_=false;reason_="available_memory_unknown";return;}
        if(warned){needed_=true;reason_="system_memory_warning_admission_paused";return;}
        if(budget_shrink){needed_=true;reason_="global_budget_shrinking";return;}
        if(available<=enter_){needed_=true;reason_="measured_low_process_headroom";}
        else if(available>=leave_){needed_=false;reason_="process_headroom_recovered";}
        else reason_=needed_?"retain_low_headroom_strategy_hysteresis":"retain_ram_strategy_hysteresis";
    }
    bool needed() const noexcept {return needed_;}
    const char* reason() const noexcept {return reason_;}
    uint64_t enter_threshold() const noexcept {return enter_;}
    uint64_t leave_threshold() const noexcept {return leave_;}
private:
    bool needed_=false;
    uint64_t enter_=enter_bytes,leave_=leave_bytes;
    const char* reason_="not_sampled";
};
struct ReadTiming final {
    std::atomic<uint64_t> requests{0},ram_reads{0},queue_us{0},read_us{0},queue_max_us{0},read_max_us{0};
    static void maximum(std::atomic<uint64_t>& field,uint64_t value) noexcept {
        auto old=field.load();while(value>old&&!field.compare_exchange_weak(old,value)){}
    }
    void record(uint64_t queued,uint64_t read,bool ram) noexcept {
        requests.fetch_add(1);if(ram)ram_reads.fetch_add(1);
        queue_us.fetch_add(queued);read_us.fetch_add(read);
        maximum(queue_max_us,queued);maximum(read_max_us,read);
    }
};
}
#ifdef NEOSWAP_STORAGE_TESTING
// Simulator-only input injection; no production API or Core ABI addition.
extern "C" void NeoSwapStorage_TestSetMemory(uint64_t available,bool valid,uint32_t pressure);
extern "C" void NeoSwapStorage_TestClearMemory(void);
#endif
