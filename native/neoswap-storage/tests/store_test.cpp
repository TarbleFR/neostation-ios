// SPDX-License-Identifier: MIT
#include "Store.h"
#include "CacheEntry.h"
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <thread>
#include <vector>
using namespace neostation::storage;
using namespace std::chrono_literals;
#define CHECK(x) do {if(!(x)){std::cerr<<"FAIL "<<__LINE__<<": "#x<<"\n";std::abort();}}while(0)
constexpr uint64_t MiB=1ULL<<20;
uint64_t next(uint64_t& x){x^=x<<13;x^=x>>7;x^=x<<17;return x;}
std::unique_ptr<Bytes> make_blob(size_t n,uint64_t seed,bool repeat=false){
    auto b=std::make_unique<Bytes>(n);auto* p=b->data();
    for(size_t i=0;i<n;++i)p[i]=repeat?uint8_t(1+(i%19)):uint8_t(next(seed));return b;
}
bool verify(const Lease& b,size_t n,uint64_t seed,bool repeat=false){
    if(b.size()!=n)return false;for(size_t i=0;i<n;++i)if(b.data()[i]!=(repeat?uint8_t(1+(i%19)):uint8_t(next(seed))))return false;return true;
}
Config config(){Config c;c.ram_bytes=4*MiB;c.warm_bytes=MiB/2;c.disk_bytes=64*MiB;c.compression=false;c.free_disk_floor=0;c.max_write_bytes_per_second=0;return c;}
Result wait(Submission s){CHECK(s.code==Code::ok);CHECK(s.completion.wait_for(10s)==std::future_status::ready);return s.completion.get();}
Result acquire(Store& s,Handle h,bool speculative=false){for(unsigned i=0;i<1000;++i){auto q=s.request(h,speculative);if(q.code==Code::busy){std::this_thread::sleep_for(1ms);continue;}if(q.code!=Code::ok)return {q.code,0,{}};return wait(std::move(q));}CHECK(false);return {};}
Handle put(Store& s,std::unique_ptr<Bytes> b,Heat heat=Heat::cold){
    for(unsigned i=0;i<1000;++i){auto q=s.publish(b,heat);if(q.code==Code::busy){CHECK(b);std::this_thread::sleep_for(1ms);continue;}CHECK(q.code==Code::ok);CHECK(!b);auto h=q.handle;CHECK(wait(std::move(q)).code==Code::ok);return h;}CHECK(false);return {};
}
void test_cycle(const std::string& dir){
    auto c=config();c.disk_bytes=128*MiB;Store s(dir,c);std::vector<Handle> ids;
    for(unsigned i=1;i<=24;++i)ids.push_back(put(s,make_blob(MiB,i)));
    auto st=s.snapshot();CHECK(st.logical_bytes==24*MiB);CHECK(st.disk_only_logical_bytes>=20*MiB);CHECK(st.raw_ram_bytes<=c.ram_bytes);
    CHECK(st.allocated_file_bytes>=24*MiB);CHECK(st.stored_payload_bytes==24*MiB);CHECK(st.bytes_written>=24*MiB);
    CHECK(wait(s.trim()).code==Code::ok);CHECK(s.snapshot().raw_ram_bytes==0);
    for(unsigned i=0;i<ids.size();++i){auto r=acquire(s,ids[(i*7)%ids.size()]);CHECK(r.code==Code::ok);CHECK(verify(r.lease,MiB,(i*7)%ids.size()+1));}
    CHECK(s.snapshot().disk_hits==24);CHECK(s.snapshot().managed_ram_peak<=c.ram_bytes+c.max_blob);
    CHECK(s.request({ids[0].session+1,ids[0].id}).code==Code::missing);
}
void test_hot_pinned(const std::string& dir){
    auto c=config();c.ram_bytes=2*MiB;c.warm_bytes=0;Store s(dir,c);
    auto a=put(s,make_blob(MiB,1),Heat::hot);auto b=put(s,make_blob(MiB,2),Heat::cold);auto d=put(s,make_blob(MiB,3),Heat::hot);
    CHECK(s.try_acquire(b).code==Code::busy);auto held=acquire(s,a);CHECK(held.code==Code::ok);
    s.set_pressure(Pressure::critical);CHECK(wait(s.trim()).code==Code::ok);CHECK(verify(held.lease,MiB,1));
    CHECK(s.snapshot().raw_ram_bytes==MiB);CHECK(s.erase(a)==Code::busy);
    auto input=make_blob(MiB,99);CHECK(s.publish(input).code==Code::pressure);CHECK(input&&input->data()[0]!=0xff);input->data()[0]=0xff;CHECK(input->data()[0]==0xff);
    CHECK(s.request(d,true).code==Code::pressure);
    held.lease.bytes.reset();CHECK(wait(s.trim()).code==Code::ok);CHECK(s.snapshot().raw_ram_bytes==0);
    auto demand=acquire(s,d);CHECK(demand.code==Code::ok);CHECK(verify(demand.lease,MiB,3));
    demand.lease.bytes.reset();CHECK(wait(s.trim()).code==Code::ok);s.set_pressure(Pressure::normal);
    CHECK(acquire(s,d,true).code==Code::ok);auto pref=acquire(s,d);CHECK(verify(pref.lease,MiB,3));CHECK(s.snapshot().prefetch_used==1);
}
void test_compression(const std::string& dir){
    auto c=config();c.compression=true;c.compression_budget_us=1000000;Store s(dir,c);
    auto h=put(s,make_blob(MiB,4,true));auto st=s.snapshot();CHECK(st.compression_accepted==1);CHECK(st.raw_ram_bytes==0);CHECK(st.compressed_ram_bytes<MiB/2);CHECK(st.stored_payload_bytes<MiB/2);
    {auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,MiB,4,true));}CHECK(s.snapshot().warm_hits==1);
    CHECK(wait(s.trim()).code==Code::ok);{auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,MiB,4,true));}CHECK(s.snapshot().disk_hits==1);
    auto random=put(s,make_blob(MiB,912));(void)random;CHECK(s.snapshot().compression_attempts==2);CHECK(s.snapshot().compression_accepted==1);
}
void test_errors(const std::string& dir){
    for(auto fault:{Store::Fault::write_error,Store::Fault::sync_error}){
        Store s(dir,config());auto b=make_blob(MiB,51);s.inject(fault);auto q=s.publish(b);CHECK(q.code==Code::ok&&!b);auto h=q.handle;
        CHECK(wait(std::move(q)).code==Code::io);CHECK(wait(s.trim()).code==Code::ok);
        auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,MiB,51));CHECK(s.snapshot().disk_only_logical_bytes==0);CHECK(s.snapshot().io_errors==1);
    }
    for(auto fault:{Store::Fault::read_error,Store::Fault::corrupt,Store::Fault::truncate}){
        Store s(dir,config());auto h=put(s,make_blob(MiB,71));CHECK(wait(s.trim()).code==Code::ok);s.inject(fault);auto r=acquire(s,h);
        CHECK(r.code!=Code::ok&&!r.lease.bytes);if(fault==Store::Fault::read_error){auto retry=acquire(s,h);CHECK(retry.code==Code::ok&&verify(retry.lease,MiB,71));}
        CHECK(s.snapshot().loading_reserved_bytes==0);
    }
    {Store s(dir,config());s.inject(Store::Fault::short_io);auto h=put(s,make_blob(MiB,101));CHECK(wait(s.trim()).code==Code::ok);s.inject(Store::Fault::short_io);auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,MiB,101));}
    {auto c=config();c.disk_bytes=MiB;Store s(dir,c);auto b=make_blob(MiB,6);auto q=s.publish(b);auto h=q.handle;CHECK(wait(std::move(q)).code==Code::io);CHECK(s.snapshot().reserved_file_bytes==0);CHECK(verify(acquire(s,h).lease,MiB,6));}
    {auto c=config();c.free_disk_floor=UINT64_MAX;Store s(dir,c);auto b=make_blob(65536,1);auto q=s.publish(b);CHECK(wait(std::move(q)).code==Code::io);}
}
void test_boundaries(const std::string& dir){
    auto c=config();c.max_entries=2;Store s(dir,c);auto empty=std::make_unique<Bytes>();CHECK(s.publish(empty).code==Code::invalid&&empty);auto a=put(s,make_blob(65536,1));auto b=put(s,make_blob(65536,2));
    auto rejected=make_blob(65536,3);CHECK(s.publish(rejected).code==Code::quota&&rejected);rejected->data()[0]=42;CHECK(rejected->data()[0]==42);
    CHECK(s.erase(a)==Code::ok);CHECK(s.request(a).code==Code::missing);CHECK(s.erase(b)==Code::ok);
    auto oversized=make_blob(2*MiB,1);CHECK(s.publish(oversized).code==Code::invalid&&oversized);
    Lease survives;{Store transient(dir,c);auto h=put(transient,make_blob(65536,49));survives=acquire(transient,h).lease;}CHECK(verify(survives,65536,49));
}
void test_concurrency(const std::string& dir){
    auto c=config();c.max_queue=2;Store s(dir,c);std::vector<std::thread> threads;
    for(unsigned t=0;t<4;++t)threads.emplace_back([&,t]{for(unsigned i=1;i<=16;++i){const uint64_t seed=1+t*16+i;auto h=put(s,make_blob(65536,seed));auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,65536,seed));}});
    for(auto& t:threads)t.join();CHECK(wait(s.barrier()).code==Code::ok);CHECK(s.snapshot().logical_bytes==4*MiB);CHECK(s.snapshot().queue_peak<=2);
}
void test_priority(const std::string& dir){
    auto c=config();c.max_write_bytes_per_second=MiB;Store s(dir,c);
    auto h=put(s,make_blob(MiB,22));CHECK(wait(s.trim()).code==Code::ok);auto b=make_blob(MiB,23);auto second=s.publish(b);CHECK(second.code==Code::ok);
    const auto start=std::chrono::steady_clock::now();auto read=acquire(s,h);const auto elapsed=std::chrono::steady_clock::now()-start;
    CHECK(read.code==Code::ok&&verify(read.lease,MiB,22));CHECK(elapsed<500ms);CHECK(wait(std::move(second)).code==Code::ok);
}
void test_recycle_and_merge(const std::string& dir){
    auto c=config();c.disk_bytes=2*MiB;Store s(dir,c);
    auto a=put(s,make_blob(256*1024,201));auto b=put(s,make_blob(128*1024,202));
    auto tail=put(s,make_blob(96*1024,203));const auto high=s.snapshot().reserved_file_bytes;
    CHECK(s.erase(a)==Code::ok&&s.erase(b)==Code::ok);
    auto joined=put(s,make_blob(320*1024,204));CHECK(s.snapshot().reserved_file_bytes==high);
    CHECK(wait(s.trim()).code==Code::ok);
    {auto r=acquire(s,tail);CHECK(r.code==Code::ok&&verify(r.lease,96*1024,203));}
    {auto r=acquire(s,joined);CHECK(r.code==Code::ok&&verify(r.lease,320*1024,204));}
    CHECK(s.erase(joined)==Code::ok);
    for(unsigned i=0;i<300;++i){
        auto h=put(s,make_blob(64*1024,1000+i));CHECK(wait(s.trim()).code==Code::ok);
        {auto r=acquire(s,h);CHECK(r.code==Code::ok&&verify(r.lease,64*1024,1000+i));}
        CHECK(s.erase(h)==Code::ok);CHECK(s.request(h).code==Code::missing);
    }
    const auto st=s.snapshot();CHECK(st.bytes_written>c.disk_bytes*8);
    CHECK(st.reserved_file_bytes==high&&st.reused_extent_count>=300);
    CHECK(st.reusable_file_bytes>0&&st.allocated_file_bytes<=c.disk_bytes);
    CHECK(wait(s.trim()).code==Code::ok);
    {auto r=acquire(s,tail);CHECK(r.code==Code::ok&&verify(r.lease,96*1024,203));}
}
void test_discard_pending_and_pinned(const std::string& dir){
    auto c=config();c.max_write_bytes_per_second=2*MiB;Store s(dir,c);
    auto first=put(s,make_blob(MiB,301));
    auto pending=s.request(first);CHECK(pending.code==Code::ok);
    CHECK(s.discard(first)==Code::ok);CHECK(s.request(first).code==Code::missing);
    auto lease=wait(std::move(pending));CHECK(lease.code==Code::ok&&verify(lease.lease,MiB,301));
    CHECK(wait(s.barrier()).code==Code::ok);CHECK(s.snapshot().logical_bytes==MiB);
    lease.lease.bytes.reset();CHECK(wait(s.barrier()).code==Code::ok);
    CHECK(s.snapshot().logical_bytes==0&&s.snapshot().discarded_entries==1);
    auto data=make_blob(MiB,302);auto write=s.publish(data);CHECK(write.code==Code::ok);
    CHECK(s.discard(write.handle)==Code::ok);CHECK(wait(std::move(write)).code==Code::ok);
    CHECK(wait(s.barrier()).code==Code::ok);CHECK(s.snapshot().logical_bytes==0);
    s.inject(Store::Fault::sync_error);data=make_blob(MiB,303);write=s.publish(data);auto h=write.handle;
    CHECK(wait(std::move(write)).code==Code::io);CHECK(verify(acquire(s,h).lease,MiB,303));
    CHECK(s.discard(h)==Code::ok);CHECK(wait(s.barrier()).code==Code::ok);
    CHECK(s.snapshot().logical_bytes==0&&s.snapshot().reusable_file_bytes>0);
    auto next=put(s,make_blob(MiB,304));CHECK(wait(s.trim()).code==Code::ok);
    CHECK(verify(acquire(s,next).lease,MiB,304));CHECK(s.snapshot().reused_extent_count>=2);
}
void test_cache_entry(const std::string& dir){
    auto store=std::make_shared<Store>(dir,config());
    CacheEntry rejected(make_blob(65536,401));
    store->set_pressure(Pressure::warning);
    CHECK(rejected.offload(store).code==Code::pressure&&rejected.local()!=nullptr);
    store->set_pressure(Pressure::normal);
    Lease survives;
    {
        CacheEntry cached(make_blob(MiB,402));auto q=cached.offload(store);
        CHECK(q.code==Code::ok&&cached.local()==nullptr);CHECK(wait(std::move(q)).code==Code::ok);
        CHECK(wait(store->trim()).code==Code::ok);CHECK(cached.try_acquire().code==Code::busy);
        auto read=cached.request();CHECK(read.code==Code::ok);
        auto r=wait(std::move(read));CHECK(r.code==Code::ok&&verify(r.lease,MiB,402));
        survives=std::move(r.lease);
    }
    CHECK(wait(store->barrier()).code==Code::ok);CHECK(verify(survives,MiB,402));
    CHECK(store->snapshot().pinned_raw_bytes==MiB);
    survives.bytes.reset();CHECK(wait(store->barrier()).code==Code::ok);
    CHECK(store->snapshot().logical_bytes==0);
}
int main(int argc,char** argv){
    CHECK(argc==2);std::filesystem::create_directories(argv[1]);
    test_cycle(argv[1]);test_hot_pinned(argv[1]);test_compression(argv[1]);test_errors(argv[1]);test_boundaries(argv[1]);test_concurrency(argv[1]);test_priority(argv[1]);test_recycle_and_merge(argv[1]);test_discard_pending_and_pinned(argv[1]);test_cache_entry(argv[1]);
    std::cout<<"PASS: real POSIX file round trips, larger-than-RAM working set, hot/cold, compression, lease safety, pressure, read priority, quotas, short I/O, ENOSPC, sync/read failures, corruption, truncation, concurrency, teardown, reusable extents, coalescing, stale IDs, deferred ownership retirement\n";
}
