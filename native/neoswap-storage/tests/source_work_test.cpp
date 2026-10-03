// SPDX-License-Identifier: MIT
#include "SourceArchive.h"
#include "../../../packages/neo_swap/ios/Classes/NeoSwapSourceWork.h"
#include <cstdlib>
#include <deque>
#include <functional>
#include <iostream>
#include <string>
#include <thread>
using namespace neostation::source_archive;
using neostation::source_work::Queue;
#define CHECK(v) do{if(!(v)){std::cerr<<"FAIL "<<__LINE__<<": " #v "\n";std::abort();}}while(0)
static Config config(){Config c;c.domain_mask=15;c.managed.store.free_disk_floor=0;
    c.managed.store.max_write_bytes_per_second=0;c.managed.store.compression=false;return c;}
static std::string fixture(size_t n){std::string s(n,'\0');uint32_t random=1711;
    for(auto& b:s){random^=random<<13;random^=random>>17;random^=random<<5;b=static_cast<char>(random);}return s;}
static void memory_need(){
    using neostation::source_work::VideoMemoryNeed;VideoMemoryNeed p;
    p.update(2ULL<<30,true,false);CHECK(!p.needed());
    p.update(512ULL<<20,true,false);CHECK(p.needed());
    p.update(1200ULL<<20,true,false);CHECK(p.needed()); // hysteresis retains a measured need
    p.update(2ULL<<30,true,false);CHECK(!p.needed());
    p.update(512ULL<<20,true,true);CHECK(p.needed());
    p.update(512ULL<<20,true,false);CHECK(p.needed()); // NORMAL recovery / still low RAM
    p.update(0,false,false);CHECK(!p.needed());
    p.update(0,false,true);CHECK(!p.needed()); // an event does not invent a valid margin
}
static void coalescing(){
    Queue q;CHECK(q.request());
    for(unsigned i=0;i<1000;++i)CHECK(!q.request());
    for(unsigned i=1;i<=512;++i)CHECK(!q.discard(1,i));
    CHECK(q.coalesced()==1512&&q.pending_discards()==512);
    unsigned consumed=0,callbacks=0;
    do{auto b=q.begin();CHECK(b.count<=Queue::discard_quantum);consumed+=b.count;++callbacks;}
    while(q.finish(false));
    CHECK(consumed==512&&callbacks==8&&q.pending_discards()==0);
    CHECK(q.request());q.demand_begin();q.defer();CHECK(q.demand_pending());
    CHECK(q.demand_end());CHECK(q.resume());(void)q.begin();CHECK(!q.finish(false));
    q.demand_begin();CHECK(q.demand_end());CHECK(!q.resume()); // a read creates no needless maintenance
    // Requests racing an executing quantum remain coalesced; no lost wakeup.
    CHECK(q.request());(void)q.begin();
    std::thread requester([&]{for(unsigned i=0;i<1000;++i)CHECK(!q.request());});requester.join();
    CHECK(q.finish(false));(void)q.begin();CHECK(!q.finish(false));
}
static void archive_demand_order(const std::string& directory){
    constexpr size_t bytes=256*1024;const auto input=fixture(bytes);
    Archive legacy(directory,81,config());uint64_t legacy_ids[4]{};
    for(auto& id:legacy_ids){auto a=legacy.admit(3,input.data(),input.size());CHECK(a.code==NS_SOURCE_OK);id=a.object;}
    // Build399's four admission callbacks each executed a WHOLE record before
    // a later sync read. This uses actual private files, Store and checkpoint.
    for(unsigned i=0;i<4;++i)legacy.maintain();
    const auto old=legacy.snapshot();CHECK(old.archived_bytes==4*bytes&&old.pending==0);

    Archive a(directory,82,config());uint64_t ids[4]{};Queue q;
    std::deque<std::function<void()>> fifo;unsigned scheduled=0,demand_seen=0;
    std::function<void()> maintenance;
    maintenance=[&]{
        if(q.demand_pending()){q.defer();return;}
        const auto b=q.begin();for(size_t i=0;i<b.count;++i)if(b.discards[i].epoch==82)a.discard(b.discards[i].object);
        const bool more=a.maintain(1,4);
        if(q.finish(more)){++scheduled;fifo.push_back(maintenance);}
    };
    for(auto& id:ids){auto result=a.admit(3,input.data(),input.size());CHECK(result.code==NS_SOURCE_OK);id=result.object;
        if(q.request()){++scheduled;fifo.push_back(maintenance);}}
    CHECK(fifo.size()==1&&scheduled==1);auto work=std::move(fifo.front());fifo.pop_front();work();
    const auto partial=a.snapshot();CHECK(partial.managed.checkpointed_bytes==65536);
    CHECK(partial.pending==4&&partial.staging_bytes==4*bytes&&partial.archived_bytes==0);
    // Partial progress never frees the accepted complete snapshot. The Core
    // RAM fast path needs no disk read, even if another chunk is scheduled.
    std::string output(bytes,'\0');CHECK(a.try_read_staging(ids[0],output.data(),output.size())==NS_SOURCE_OK&&output==input);
    CHECK(a.snapshot().managed.store.bytes_read==partial.managed.store.bytes_read);
    q.demand_begin();fifo.push_back([&]{
        int error=0;CHECK(a.read(ids[0],output.data(),output.size(),error)==NS_SOURCE_OK&&output==input&&error==0);
        ++demand_seen;CHECK(a.snapshot().managed.checkpointed_bytes==65536);
        CHECK(q.demand_end());if(q.resume()){++scheduled;fifo.push_back(maintenance);}
    });
    work=std::move(fifo.front());fifo.pop_front();work(); // preceding continuation yields to demand
    CHECK(a.snapshot().managed.checkpointed_bytes==65536);
    work=std::move(fifo.front());fifo.pop_front();work();CHECK(demand_seen==1);
    CHECK(fifo.size()==1); // one rearmed continuation, no admission/discard avalanche
    while(!fifo.empty()){work=std::move(fifo.front());fifo.pop_front();work();}
    const auto cold=a.snapshot();CHECK(cold.pending==0&&cold.archived_bytes==4*bytes&&cold.staging_bytes==0);
    CHECK(cold.managed.checkpointed_bytes==4*bytes); // no repeated completed writes
    CHECK(a.try_read_staging(ids[0],output.data(),output.size())==NS_SOURCE_BUSY);
    int error=0;CHECK(a.read(ids[0],output.data(),output.size(),error)==NS_SOURCE_OK&&output==input);
    for(auto id:ids)a.discard(id);
    CHECK(!a.maintain(1,4));CHECK(a.snapshot().sources==0);
    CHECK(a.try_read_staging(ids[0],output.data(),output.size())==NS_SOURCE_MISSING);
}
static void interrupted_quantum(const std::string& directory){
    Archive a(directory,83,config());const auto input=fixture(3*65536);
    const auto admitted=a.admit(3,input.data(),input.size());CHECK(admitted.code==NS_SOURCE_OK);
    CHECK(a.maintain(1,4));const auto before=a.snapshot();CHECK(before.managed.checkpointed_bytes==65536&&before.pending==1);
    a.pressure(neostation::storage::Pressure::warning);CHECK(!a.maintain(1,4));
    std::string output(input.size(),'\0');CHECK(a.try_read_staging(admitted.object,output.data(),output.size())==NS_SOURCE_OK&&output==input);
    CHECK(a.snapshot().managed.checkpointed_bytes==65536&&a.snapshot().archive_failures==0);
    a.pressure(neostation::storage::Pressure::normal);CHECK(a.maintain(1,4));CHECK(!a.maintain(1,4));
    CHECK(a.snapshot().managed.checkpointed_bytes==input.size()&&a.snapshot().pending==0);
    int error=0;CHECK(a.read(admitted.object,output.data(),output.size(),error)==NS_SOURCE_OK&&output==input);
    a.discard(admitted.object);CHECK(!a.maintain(1,4));CHECK(a.snapshot().sources==0);
    // Discard a partially checkpointed object: no write of its remaining chunks.
    auto next=a.admit(3,input.data(),input.size());CHECK(next.code==NS_SOURCE_OK);CHECK(a.maintain(1,4));
    const auto written=a.snapshot().managed.checkpointed_bytes;a.discard(next.object);CHECK(!a.maintain(1,4));
    CHECK(a.snapshot().managed.checkpointed_bytes==written&&a.snapshot().sources==0&&a.snapshot().staging_bytes==0);
}
int main(int argc,char** argv){CHECK(argc==2);memory_need();coalescing();archive_demand_order(argv[1]);interrupted_quantum(argv[1]);
    std::cout<<"{\"passed\":true,\"actualPrivateFileCheckpointAndRestore\":true,\"wholeRecordFifoBacklogReproduced\":true,"
        "\"demandPrecedesContinuation\":true,\"maintenanceCoalesced\":true,\"ramDemandNoDiskIO\":true,"
        "\"partialQuantumRetainsFullSnapshot\":true,\"pressureResumeExact\":true,\"invalidMemoryFailsClosed\":true,"
        "\"physicalIPhoneValidated\":false,\"realRPCS3GameplayValidated\":false}\n";}
