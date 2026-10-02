// SPDX-License-Identifier: MIT
// Synthetic immutable CPU blobs, NOT a God of War III workload.
#include "Store.h"
#include "ApplePressure.h"
#include <algorithm>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <numeric>
#include <thread>
#include <vector>
using namespace neostation::storage;
using Clock = std::chrono::steady_clock;
constexpr uint64_t MiB=1ULL<<20;
uint64_t next(uint64_t& x){x^=x<<13;x^=x>>7;x^=x<<17;return x;}
uint8_t byte_at(size_t i,uint64_t& seed,bool repeat){return repeat?uint8_t(1+i%19):uint8_t(next(seed));}
std::unique_ptr<Bytes> make_blob(unsigned id,bool repeat){auto p=std::make_unique<Bytes>(MiB);uint64_t seed=id+1;for(size_t i=0;i<MiB;++i)p->data()[i]=byte_at(i,seed,repeat);return p;}
void verify(const uint8_t* p,unsigned id,bool repeat){uint64_t seed=id+1;for(size_t i=0;i<MiB;++i)if(p[i]!=byte_at(i,seed,repeat))throw std::runtime_error("round-trip mismatch");}
uint64_t elapsed(Clock::time_point t){return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now()-t).count();}
uint64_t percentile(std::vector<uint64_t> a,unsigned p){std::sort(a.begin(),a.end());return a.empty()?0:a[((a.size()-1)*p+99)/100];}
template<class Operation> Submission retry_busy(Operation&& operation){
    const auto deadline=Clock::now()+std::chrono::seconds(1);
    for(;;){auto q=operation();if(q.code!=Code::busy||Clock::now()>=deadline)return q;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));}
}
Result wait(Submission q){if(q.code!=Code::ok)throw std::runtime_error("request rejected code="+std::to_string(static_cast<int>(q.code)));if(q.completion.wait_for(std::chrono::seconds(30))!=std::future_status::ready)throw std::runtime_error("worker timeout");auto r=q.completion.get();if(r.code!=Code::ok)throw std::runtime_error("I/O or integrity failure code="+std::to_string(static_cast<int>(r.code))+" errno="+std::to_string(r.os_error));return r;}
struct Sampler{
    ProcessMetrics before=sample_process(),after{},cold{};uint64_t peak_resident=before.resident_bytes,peak_footprint=before.footprint_bytes;
    void tick(){auto m=sample_process();peak_resident=std::max(peak_resident,m.resident_bytes);peak_footprint=std::max(peak_footprint,m.footprint_bytes);}
    static void metric(const char* key,uint64_t n,bool valid){std::cout<<",\""<<key<<"\":";if(valid)std::cout<<n;else std::cout<<"null";}
    void print(){metric("residentBeforeBytes",before.resident_bytes,before.resident_valid);metric("residentPeakSampledBytes",peak_resident,before.resident_valid);metric("residentAfterTrimBytes",cold.resident_bytes,cold.resident_valid);metric("residentEndBytes",after.resident_bytes,after.resident_valid);metric("footprintPeakSampledBytes",peak_footprint,before.footprint_valid);metric("compressedAccountedEndBytes",after.compressed_accounted_bytes,after.compressed_valid);metric("processAvailableEndBytes",after.process_available_bytes,after.process_available_valid);}
};
int main(int argc,char** argv){try{
    if(argc!=6)throw std::runtime_error("benchmark private-dir heap|store raw|compressed count write-bytes-per-second");
    const std::string dir=argv[1],mode=argv[2],pattern=argv[3];const unsigned count=std::stoul(argv[4]);const uint64_t rate=std::stoull(argv[5]);
    if((mode!="heap"&&mode!="store")||(pattern!="raw"&&pattern!="compressed")||count<16||count>256||std::gcd(count,17U)!=1)throw std::runtime_error("arguments");
    std::filesystem::create_directories(dir);const bool repeat=pattern=="compressed";Sampler mem;std::vector<uint64_t> latency;uint64_t publish_us=0,issue_p95=0;Stats stats{};
    if(mode=="heap"){
        std::vector<std::unique_ptr<Bytes>> buffers;const auto t=Clock::now();for(unsigned i=0;i<count;++i){buffers.push_back(make_blob(i,repeat));mem.tick();}publish_us=elapsed(t);mem.cold=sample_process();
        for(unsigned i=0;i<count;++i){const unsigned index=(i*17)%count;const auto t0=Clock::now();const uint8_t* p=buffers[index]->data();volatile uint8_t touch=p[0];(void)touch;latency.push_back(elapsed(t0));verify(p,index,repeat);mem.tick();}mem.after=sample_process();stats.logical_bytes=count*MiB;stats.raw_ram_bytes=count*MiB;stats.managed_ram_peak=count*MiB;
    }else{
        Config c;c.ram_bytes=8*MiB;c.warm_bytes=MiB;c.disk_bytes=384*MiB;c.free_disk_floor=512*MiB;c.compression=true;c.max_write_bytes_per_second=rate;
        Store s(dir,c);
#ifdef __APPLE__
        ApplePressure monitor(s);if(!monitor.active())throw std::runtime_error("memory pressure source unavailable");
#endif
        std::vector<Handle> ids;std::vector<uint64_t> issues;const auto t=Clock::now();
        for(unsigned i=0;i<count;++i){auto b=make_blob(i,repeat);auto q=retry_busy([&]{const auto issue=Clock::now();auto submission=s.publish(b,i%8==0?Heat::hot:Heat::cold);issues.push_back(elapsed(issue));if(submission.code==Code::busy&&!b)throw std::runtime_error("busy publication lost ownership");return submission;});ids.push_back(q.handle);wait(std::move(q));mem.tick();}
        publish_us=elapsed(t);issue_p95=percentile(issues,95);wait(retry_busy([&]{return s.trim();}));mem.cold=sample_process();
        for(unsigned i=0;i<count;++i){const unsigned index=(i*17)%count;const auto t0=Clock::now();Submission q;
            q=retry_busy([&]{return s.request(ids[index]);});auto r=wait(std::move(q));latency.push_back(elapsed(t0));verify(r.lease.data(),index,repeat);mem.tick();}
        stats=s.snapshot();mem.after=sample_process();
    }
    std::cout<<"{\"schema\":1,\"synthetic\":true,\"realRPCS3GameplayValidated\":false,\"physicalIPhoneValidated\":false,\"mode\":\""<<mode<<"\",\"pattern\":\""<<pattern<<"\",\"codec\":\""<<codec_name()<<"\",\"blockBytes\":"<<MiB<<",\"logicalBytes\":"<<count*MiB<<",\"ramBudgetBytes\":"<<(mode=="store"?8*MiB:count*MiB)<<",\"writeRateLimitBytesPerSecond\":"<<rate<<",\"publishIncludingDataGenerationUs\":"<<publish_us<<",\"publishIssueP95Us\":"<<issue_p95<<",\"demandRoundTripP50Us\":"<<percentile(latency,50)<<",\"demandRoundTripP95Us\":"<<percentile(latency,95)<<",\"demandRoundTripP99Us\":"<<percentile(latency,99);
#define OUT(field) std::cout<<",\"" #field "\":"<<stats.field
    OUT(logical_bytes);OUT(raw_ram_bytes);OUT(compressed_ram_bytes);OUT(pinned_raw_bytes);OUT(disk_only_logical_bytes);OUT(stored_payload_bytes);OUT(allocated_file_bytes);OUT(reserved_file_bytes);OUT(reusable_file_bytes);OUT(reused_extent_count);OUT(discarded_entries);OUT(bytes_read);OUT(bytes_written);OUT(read_calls);OUT(write_calls);OUT(evicted_logical_bytes);OUT(restored_logical_bytes);OUT(warm_hits);OUT(ram_hits);OUT(disk_hits);OUT(prefetch_used);OUT(prefetch_wasted);OUT(prefetch_cancelled);OUT(io_errors);OUT(corruptions);OUT(quota_refusals);OUT(backpressure);OUT(compression_attempts);OUT(compression_accepted);OUT(compression_input_bytes);OUT(compression_output_bytes);OUT(compression_us);OUT(decompression_us);OUT(worker_scratch_peak);OUT(queue_peak);OUT(managed_ram_peak);OUT(read_p50_us);OUT(read_p95_us);OUT(read_p99_us);OUT(read_max_us);OUT(write_p95_us);OUT(queue_p95_us);OUT(restore_p95_us);
#undef OUT
    mem.print();std::cout<<",\"contentVerified\":true,\"nandReadLatencyProven\":false}\n";
}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
