// SPDX-License-Identifier: MIT
#include "ShaderCache.h"
#include "Client.h"
#include "SessionSlot.h"
#include <cassert>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <thread>
using namespace neostation::storage;
using namespace std::chrono_literals;
namespace client=neostation::storage_client;
static ShaderCache* cache=nullptr;
static uint64_t generation=91;
static bool publish_rejected=false;
static uint64_t releases=0;
static ShaderKey key_of(const uint8_t* key){ShaderKey out;std::memcpy(out.data(),key,32);return out;}
static uint64_t session(){return generation;}
static int get(uint64_t session,const uint8_t* key,NeoSwapStorageView* out){
    *out={};if(session!=generation||!cache)return NS_STORAGE_DISABLED;
    auto r=cache->acquire(key_of(key));if(r.code!=Code::ok)return NS_STORAGE_MISS;
    auto* lease=new Lease(std::move(r.lease));out->words=reinterpret_cast<const uint32_t*>(lease->data());out->byte_count=lease->size();out->lease=lease;return NS_STORAGE_OK;
}
static int put(uint64_t session,const uint8_t* key,const uint32_t* words,uint64_t n){
    if(publish_rejected)return NS_STORAGE_BUSY;
    if(session!=generation||!cache)return NS_STORAGE_DISABLED;
    return cache->publish(key_of(key),words,n)==Code::ok?NS_STORAGE_OK:NS_STORAGE_BUSY;
}
static void release(NeoSwapStorageView* view){delete static_cast<Lease*>(view->lease);*view={};++releases;}
static void prefetch(uint64_t session,const uint8_t* key){if(cache&&session==generation)cache->prefetch(key_of(key));}
static void invalidate(uint64_t session,const uint8_t* key){if(cache&&session==generation)cache->invalidate(key_of(key));}
static void event(uint64_t session,uint32_t type,uint64_t bytes){if(cache&&session==generation)cache->event(type,bytes);}
static const NeoSwapStorageAPI api{sizeof(NeoSwapStorageAPI),NEOSWAP_STORAGE_ABI,session,get,put,release,prefetch,invalidate,event};
static std::vector<uint32_t> binary(unsigned seed){
    std::vector<uint32_t> out(16384);
    uint32_t x=seed;
    for(auto& n:out){x^=x<<13;x^=x>>17;x^=x<<5;n=x;}
    out[0]=0x07230203;out[1]=0x00010500;out[3]=64;out[4]=0;return out;
}
static void settle(ShaderCache& s){auto b=s.test_store().barrier();assert(b.code==Code::ok);assert(b.completion.wait_for(5s)==std::future_status::ready);assert(b.completion.get().code==Code::ok);s.maintain();}
static void trim(ShaderCache& s){settle(s);auto q=s.test_store().trim();assert(q.code==Code::ok);assert(q.completion.wait_for(5s)==std::future_status::ready);assert(q.completion.get().code==Code::ok);}
static client::Ticket ticket(unsigned seed){auto t=client::ticket();t.key[0]=seed;return t;}
static Result await_cache(ShaderCache& s,ShaderKey key){for(int i=0;i<1000;++i){auto r=s.acquire(key);if(r.code==Code::ok)return r;std::this_thread::sleep_for(1ms);}assert(false);return {};}
int main(int argc,char** argv){
    assert(argc==2);std::filesystem::create_directories(argv[1]);
    auto bad=api;bad.struct_size=1;assert(client::install(&bad)==NS_STORAGE_INVALID);assert(client::install(&api)==NS_STORAGE_OK);assert(client::install(&api)==NS_STORAGE_OK);
    Config c;c.ram_bytes=2ULL<<20;c.warm_bytes=0;c.disk_bytes=8ULL<<20;c.free_disk_floor=0;c.compression=false;c.max_entries=32;c.max_write_bytes_per_second=0;
    ShaderCache store(argv[1],generation,c);cache=&store;
    auto t=ticket(1);const auto expected=binary(11);std::vector<uint32_t> owned;
    int compiles=0,modules=0;
    auto build=[&](auto& out){++compiles;out=expected;return true;};
    auto create=[&](const uint32_t* words,size_t n){++modules;assert(n==expected.size()*4);assert(!std::memcmp(words,expected.data(),n));return client::ModuleResult::ok;};
    for(int attempt=0;attempt<100;++attempt){
        assert(client::compile(t,owned,build,create)==client::CompileResult::ok);
        if(owned.empty())break;
        std::this_thread::sleep_for(1ms);
    }
    assert(compiles>=1&&modules==compiles&&owned.empty());const int initialModules=modules;
    settle(store);assert(store.snapshot().store.bytes_written>0);trim(store);
    assert(store.snapshot().store.disk_only_logical_bytes==expected.size()*4);
    auto miss=store.acquire(t.key);assert(miss.code==Code::busy);
    {auto restored=await_cache(store,t.key);assert(restored.lease.size()==expected.size()*4);}
    int before=compiles;assert(client::compile(t,owned,build,create)==client::CompileResult::ok);assert(compiles==before&&modules==initialModules+1&&releases>0);
    assert(store.snapshot().store.restored_logical_bytes>=expected.size()*4);
    assert(client::compile(t,owned,build,[&](auto* p,size_t n){store.pressure(Pressure::critical);trim(store);assert(n==expected.size()*4&&!std::memcmp(p,expected.data(),n));return client::ModuleResult::ok;})==client::CompileResult::ok);
    store.pressure(Pressure::normal);
    {auto restored=await_cache(store,t.key);}
    unsigned calls=0;before=compiles;
    assert(client::compile(t,owned,build,[&](auto* p,size_t n){assert(n==expected.size()*4&&!std::memcmp(p,expected.data(),n));return ++calls==2?client::ModuleResult::ok:client::ModuleResult::retry_source;})==client::CompileResult::ok);
    assert(calls==2&&compiles==before+1);settle(store);
    trim(store);store.test_store().inject(Store::Fault::corrupt);
    (void)store.acquire(t.key);settle(store);before=compiles;
    assert(client::compile(t,owned,build,create)==client::CompileResult::ok);assert(compiles==before+1);settle(store);
    auto t2=ticket(2);publish_rejected=true;assert(client::compile(t2,owned,build,create)==client::CompileResult::ok);assert(owned==expected);publish_rejected=false;
    auto t3=ticket(3);assert(client::compile(t3,owned,[](auto&){return false;},create)==client::CompileResult::source_failure);
    assert(client::compile(t3,owned,build,[](auto*,size_t){return client::ModuleResult::fatal;})==client::CompileResult::module_failure);
    generation=92;before=compiles;assert(client::compile(t,owned,build,create)==client::CompileResult::ok);assert(compiles==before+1&&owned==expected);generation=91;
    for(unsigned i=4;i<80;++i){auto k=ticket(i).key;auto data=binary(i);auto result=store.publish(k,data.data(),data.size()*4);assert(result==Code::ok||result==Code::busy||result==Code::quota);settle(store);}
    auto tiny=binary(99);tiny.resize(8);auto tinyKey=ticket(99).key;
    assert(store.publish(tinyKey,tiny.data(),tiny.size()*4)==Code::invalid);
    assert(store.snapshot().tiny_refusals==1);
    store.pressure(Pressure::warning);const auto copied=store.snapshot().admission_copy_bytes;
    assert(store.publish(tinyKey,expected.data(),expected.size()*4)==Code::pressure);
    assert(store.snapshot().admission_copy_bytes==copied);store.pressure(Pressure::normal);
    SessionSlot<int> slot;auto one=std::make_shared<int>(1);assert(!slot.exchange(one));
    auto held=slot.try_load();assert(held&&*held==1);auto removed=slot.exchange(std::make_shared<int>(2));
    assert(*held==1&&removed==one&&*slot.control_load()==2);
    std::thread reader([&]{for(int i=0;i<1000;++i){auto p=slot.try_load();if(p)assert(*p>=2);}});
    for(int i=2;i<1000;++i)(void)slot.exchange(std::make_shared<int>(i));reader.join();
    auto s=store.snapshot();assert(s.entries<=32&&s.store.reserved_file_bytes<=c.disk_bytes);assert(s.store.reused_extent_count>0);
    assert(s.hits>=2&&s.source_compiles>=3&&s.cached_module_rejections==1&&s.released_cpu_copy_bytes>0);
    std::cout<<"{\"passed\":true,\"productionClientExecuted\":true,\"realFileReads\":"<<s.store.bytes_read<<",\"realFileWrites\":"<<s.store.bytes_written<<",\"shaderCacheHits\":"<<s.hits<<",\"sourceRebuilds\":"<<s.source_compiles<<",\"gpuModuleCall\":\"injected-consumer\",\"physicalIPhoneValidated\":false}\n";
    cache=nullptr;
}
