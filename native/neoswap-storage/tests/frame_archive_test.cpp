// SPDX-License-Identifier: MIT
#include "SourceArchive.h"
#include "FrameClient.h"
#include <cstdlib>
#include <cerrno>
#include <iostream>
#include <chrono>
#include <thread>
#include <vector>
using namespace neostation::source_archive;
using namespace neostation::source_client;
#define CHECK(v) do { if(!(v)){std::cerr<<"FAIL "<<__LINE__<<": " #v "\n";std::abort();} } while(0)
namespace {
Archive* active=nullptr;
uint64_t epoch=0;
uint32_t calls=0,refuse_at=0,change_epoch_at=0;
uint32_t read_calls=0,fail_read_at=0;
uint64_t discarded=0;
uint64_t session(){return active&&active->accepting()?epoch:0;}
int admit(uint64_t e,uint32_t d,const char* p,uint64_t n,uint64_t* id){
    *id=0;++calls;
    if(calls==change_epoch_at)++epoch;
    if(!active||e!=epoch)return NS_SOURCE_MISSING;
    if(calls==refuse_at)return NS_SOURCE_BUSY;
    const auto a=active->admit(d,p,n);*id=a.object;return a.code;
}
int read(uint64_t e,uint64_t id,char* p,uint64_t n,int* error){
    *error=0;if(!active||e!=epoch)return NS_SOURCE_MISSING;
    if(++read_calls==fail_read_at){*error=EIO;return NS_SOURCE_IO;}
    return active->read(id,p,n,*error);
}
void discard(uint64_t,uint64_t id){++discarded;if(active)active->discard(id);}
void released(uint64_t,uint64_t){CHECK(false);}
const NeoSwapSourceAPI api{sizeof(api),NEOSWAP_SOURCE_ABI,session,admit,read,discard,released};
Config config(bool pixels=true){Config c;c.domain_mask=pixels?15:7;
    c.managed.store.free_disk_floor=0;c.managed.store.max_write_bytes_per_second=0;
    c.managed.store.compression=false;return c;}
std::string fixture(size_t n,uint64_t seed){std::string s(n,'\0');
    for(char& b:s){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;b=static_cast<char>(seed);}return s;}
void reset(Archive& a,uint64_t e){active=&a;epoch=e;calls=refuse_at=change_epoch_at=0;
    read_calls=fail_read_at=0;discarded=0;}
void maintain(Archive& a){for(unsigned i=0;i<frame_max_chunks;++i)a.maintain();}
void policy(){
    CHECK(frame_queue_has_room(59,0,60));
    CHECK(!frame_queue_has_room(59,1,60));
    CHECK(!frame_queue_has_room(60,0,60));
    CHECK(!frame_queue_has_room(0,60,60));
    CHECK(!frame_queue_has_room(UINT64_MAX,1,60));
    CHECK(frame_can_cool(60,0,250000,1280*720*3/2,true));
    CHECK(!frame_can_cool(23,0,250000,4096,true));
    CHECK(!frame_can_cool(60,52,250000,4096,true));
    CHECK(!frame_can_cool(60,60,250000,4096,true));
    CHECK(!frame_can_cool(60,0,249999,4096,true));
    CHECK(!frame_can_cool(60,0,250000,4095,true));
    CHECK(!frame_can_cool(60,0,250000,frame_max_bytes+1,true));
    CHECK(!frame_can_cool(60,0,250000,4096,false));
}
Stats cycle;
void large_cycle(const std::string& dir){
    Archive a(dir,9,config());reset(a,9);
    std::vector<ColdFrame> frames(48);
    constexpr size_t bytes=1280*720*3/2;
    for(size_t i=0;i<frames.size();++i){
        auto pixels=fixture(bytes,i+1);const auto before=a.snapshot();
        CHECK(frames[i].offload(pixels.data(),pixels.size()));
        CHECK(pixels==fixture(bytes,i+1)); // client NEVER frees the caller's AVFrame
        const auto accepted=a.snapshot();
        CHECK(accepted.managed.store.bytes_read==before.managed.store.bytes_read);
        CHECK(accepted.managed.store.bytes_written==before.managed.store.bytes_written);
        // The integration drops only exclusively owned AVBuffers after success.
        std::string().swap(pixels);maintain(a);
        const auto cold=a.snapshot();CHECK(cold.archive_failures==0);
        CHECK(cold.staging_bytes==0&&cold.managed.resident_mapped_bytes==0);
        CHECK(cold.staging_peak<=config().staging_bytes);
    }
    for(size_t i=0;i<frames.size();++i){
        std::string restored;int error=0;
        CHECK(frames[i].restore(restored,error)==NS_SOURCE_OK&&error==0);
        CHECK(restored==fixture(bytes,i+1));
    }
    cycle=a.snapshot();CHECK(cycle.pixel_archived_bytes==48*bytes);
    CHECK(cycle.pixel_live_archived_bytes==48*bytes);
    CHECK(cycle.pixel_restored_bytes==48*bytes&&cycle.pixel_admissions==96);
    CHECK(cycle.core_released_capacity==0); // no fraudulent GLSL capacity counter
    auto shared=frames[0];frames.clear();maintain(a);CHECK(a.snapshot().sources==2);
    shared.reset();maintain(a);CHECK(a.snapshot().sources==0&&a.snapshot().pixel_live_archived_bytes==0);
    active=nullptr;
}
void transactional(const std::string& dir){
    const auto pixels=fixture(2*1024*1024+17,321);
    for(unsigned fault=0;fault<3;++fault){
        Archive a(dir,10,config());reset(a,10);ColdFrame f;
        if(fault==0)refuse_at=2;
        if(fault==1)change_epoch_at=2;
        if(fault==2)change_epoch_at=3;
        CHECK(!f.offload(pixels.data(),pixels.size())&&!f.archived());
        CHECK(pixels==fixture(pixels.size(),321));
        maintain(a);CHECK(a.snapshot().sources==0&&a.snapshot().staging_bytes==0);
        CHECK(discarded>0);active=nullptr;
    }
    Archive old(dir,11,config(false));reset(old,11);ColdFrame f;
    CHECK(!f.offload(pixels.data(),pixels.size())); // actual old GLSL-only fallback
    CHECK(old.snapshot().sources==0&&pixels==fixture(pixels.size(),321));active=nullptr;
}
void errors(const std::string& dir){
    using Fault=neostation::storage::Store::Fault;
    const auto pixels=fixture(512*1024,44);
    for(auto fault:{Fault::write_error,Fault::sync_error,Fault::read_error,Fault::corrupt}){
        Archive a(dir,12,config());reset(a,12);ColdFrame f;
        CHECK(f.offload(pixels.data(),pixels.size()));a.inject(fault);a.maintain();
        CHECK(a.snapshot().staging_bytes==pixels.size());
        std::string restored;int error=0;
        CHECK(f.restore(restored,error)==NS_SOURCE_OK&&restored==pixels);
        f.reset();a.maintain();CHECK(a.snapshot().staging_bytes==0);active=nullptr;
    }
    Archive a(dir,13,config());reset(a,13);ColdFrame f;
    CHECK(f.offload(pixels.data(),pixels.size()));a.maintain();
    a.inject(Fault::read_error);std::string restored="stale";int error=0;
    CHECK(f.restore(restored,error)==NS_SOURCE_IO&&restored.empty()&&error!=0);
    CHECK(f.restore(restored,error)==NS_SOURCE_OK&&restored==pixels);
    ++epoch;CHECK(f.restore(restored,error)==NS_SOURCE_MISSING&&restored.empty());
    f.reset();a.maintain();active=nullptr;
}
void throttled_progress(const std::string& dir){
    auto c=config();c.managed.store.max_write_bytes_per_second=128*1024;
    Archive a(dir,14,c);reset(a,14);ColdFrame f;
    const auto pixels=fixture(3*65536,991);
    CHECK(f.offload(pixels.data(),pixels.size()));
    // A real write-rate limit plus an injected transient deferral after one
    // verified chunk. Store's rate limiter delays writes, not admission.
    a.defer_after_chunks(1);a.maintain();
    auto s=a.snapshot();CHECK(s.pending==1&&s.archive_failures==0&&s.transient_retries>0);
    CHECK(s.managed.objects==1&&s.managed.checkpointed_bytes>=65536);
    const auto progress=s.managed.checkpointed_bytes;
    // Even during a pressure pause, the complete accepted RAM snapshot stays readable.
    a.pressure(neostation::storage::Pressure::warning);a.maintain();
    std::string restored;int error=0;CHECK(f.restore(restored,error)==NS_SOURCE_OK&&restored==pixels);
    CHECK(a.snapshot().managed.checkpointed_bytes==progress);
    a.pressure(neostation::storage::Pressure::normal);
    for(unsigned i=0;i<8&&a.snapshot().pending;++i){
        std::this_thread::sleep_for(std::chrono::milliseconds(520));a.maintain();
    }
    s=a.snapshot();CHECK(s.pending==0&&s.staging_bytes==0&&s.archive_failures==0);
    CHECK(s.managed.checkpointed_bytes==pixels.size()); // no re-checkpoint of completed chunks
    CHECK(s.managed.store.bytes_written==pixels.size()+3*40); // unchanged Store header: 40 bytes per chunk
    CHECK(f.restore(restored,error)==NS_SOURCE_OK&&restored==pixels);
    f.reset();a.maintain();CHECK(a.snapshot().sources==0);active=nullptr;
}
void partial_read(const std::string& dir){
    Archive a(dir,15,config());reset(a,15);ColdFrame f;
    const auto pixels=fixture(frame_max_bytes,887);
    CHECK(f.offload(pixels.data(),pixels.size()));maintain(a);
    CHECK(a.snapshot().pending==0);
    fail_read_at=2;std::string restored="stale";int error=0;
    CHECK(f.restore(restored,error)==NS_SOURCE_IO&&error==EIO&&restored.empty());
    CHECK(f.archived());fail_read_at=0;
    CHECK(f.restore(restored,error)==NS_SOURCE_OK&&restored==pixels);
    f.reset();maintain(a);CHECK(a.snapshot().sources==0);active=nullptr;
}
}
int main(int argc,char** argv){
    CHECK(argc==2&&install(&api)==NS_SOURCE_OK);policy();large_cycle(argv[1]);transactional(argv[1]);errors(argv[1]);throttled_progress(argv[1]);partial_read(argv[1]);
    std::cout<<"{\"passed\":true,\"softwarePixelBytesSimulated\":true,\"realDecoderExecuted\":false,"
        "\"byteIdentityVerified\":true,\"transactionalAdmissionVerified\":true,\"partialRestoreNeverConsumed\":true,"
        "\"oldHostFallbackVerified\":true,\"warmAndReferencedPixelsRetained\":true,\"throttledProgressResumed\":true,\"logicalPixelBytes\":"<<cycle.pixel_archived_bytes
        <<",\"returnedPixelBytes\":"<<cycle.pixel_restored_bytes<<",\"stagingPeakBytes\":"<<cycle.staging_peak
        <<",\"physicalIPhoneValidated\":false,\"gameplayValidated\":false}\n";
}
