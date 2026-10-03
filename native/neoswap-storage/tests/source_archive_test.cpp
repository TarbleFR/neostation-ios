// SPDX-License-Identifier: MIT
#include "SourceArchive.h"
#include "SourceClient.h"
#include <cerrno>
#include <cstdlib>
#include <iostream>
#include <vector>
using namespace neostation::source_archive;
using neostation::source_client::ColdSource;
#define CHECK(v) do{if(!(v)){std::cerr<<"FAIL "<<__LINE__<<": " #v "\n";std::abort();}}while(0)
namespace {
Archive* active=nullptr;
uint64_t session(){return active && active->accepting()?active->generation():0;}
int admit(uint64_t epoch,uint32_t domain,const char* text,uint64_t bytes,uint64_t* object){
    *object=0;if(!active || epoch!=active->generation())return NS_SOURCE_MISSING;
    const auto result=active->admit(domain,text,bytes);*object=result.object;return result.code;
}
int read(uint64_t epoch,uint64_t object,char* output,uint64_t bytes,int* error){
    *error=0;if(!active || epoch!=active->generation())return NS_SOURCE_MISSING;
    return active->read(object,output,bytes,*error);
}
void discard(uint64_t epoch,uint64_t object){if(active && epoch==active->generation())active->discard(object);}
void released(uint64_t epoch,uint64_t capacity){CHECK(active && epoch==active->generation());active->released(capacity);}
const NeoSwapSourceAPI api{sizeof(api),NEOSWAP_SOURCE_ABI,session,admit,read,discard,released};
constexpr uint64_t MiB=1ULL<<20;
std::string fixture(size_t size,uint64_t seed){
    std::string value(size,' ');
    for(auto& byte:value){seed^=seed<<13;seed^=seed>>7;seed^=seed<<17;byte=static_cast<char>(seed);}
    return value;
}
Config config(){Config out;out.managed.store.free_disk_floor=0;
    out.managed.store.max_write_bytes_per_second=0;out.managed.store.compression=false;return out;}
Stats cycle;
void large_cycle(const std::string& directory){
    Archive archive(directory,1,config());active=&archive;
    std::vector<ColdSource> owners(64);
    for(uint32_t index=0;index<owners.size();++index){
        auto source=fixture(MiB,index+100);const auto before=archive.snapshot();
        CHECK(owners[index].offload(source,index%3) && source.empty());
        auto admitted=archive.snapshot();
        CHECK(admitted.managed.store.bytes_read==before.managed.store.bytes_read);
        CHECK(admitted.managed.store.bytes_written==before.managed.store.bytes_written);
        CHECK(admitted.staging_bytes==MiB && admitted.staging_bytes<=config().staging_bytes);
        archive.maintain();auto cold=archive.snapshot();
        if(cold.archive_failures)std::cerr<<"archive failure errno="<<cold.last_errno<<"\n";
        CHECK(cold.archive_failures==0 && cold.pending==0 && cold.staging_bytes==0);
        CHECK(cold.managed.owned_ram_bytes==0 && cold.managed.resident_mapped_bytes==0);
        CHECK(cold.managed.resident_mapped_peak<=cold.managed.resident_limit_bytes);
    }
    CHECK(archive.snapshot().archived_bytes==64*MiB);
    for(uint32_t step=0;step<owners.size();++step){
        const auto index=(step*7)%owners.size();std::string restored;int error=0;
        CHECK(owners[index].restore(restored,error)==NS_SOURCE_OK);
        CHECK(restored==fixture(MiB,index+100) && error==0);
    }
    cycle=archive.snapshot();CHECK(cycle.restored_bytes==64*MiB);
    CHECK(cycle.managed.store.bytes_read>=128*MiB && cycle.managed.store.bytes_written>=64*MiB);
    CHECK(cycle.core_released_capacity>=64*MiB && cycle.staging_peak<=config().staging_bytes);
    auto shared=owners[0];owners.clear();archive.maintain();CHECK(archive.snapshot().sources==1);
    shared.reset();archive.maintain();CHECK(archive.snapshot().sources==0);
    active=nullptr;
}
void pressure_and_limits(const std::string& directory){
    auto limits=config();limits.staging_bytes=MiB;Archive archive(directory,2,limits);active=&archive;
    auto source=fixture(MiB,70);const auto expected=source;ColdSource first,refused;
    CHECK(first.offload(source,0));source=expected;
    CHECK(!refused.offload(source,1) && source==expected);
    CHECK(archive.admit(3,source.data(),source.size()).code==NS_SOURCE_INVALID);
    CHECK(archive.admit(0,source.data(),4095).code==NS_SOURCE_INVALID);
    CHECK(archive.admit(0,source.data(),MiB+1).code==NS_SOURCE_INVALID);
    archive.pressure(neostation::storage::Pressure::critical);archive.maintain();
    CHECK(archive.snapshot().staging_bytes==MiB && archive.snapshot().archived_bytes==0);
    std::string restored;int error=0;CHECK(first.restore(restored,error)==NS_SOURCE_OK && restored==expected);
    CHECK(!refused.offload(source,0) && source==expected);
    archive.pressure(neostation::storage::Pressure::normal);archive.maintain();
    CHECK(archive.snapshot().staging_bytes==0 && archive.snapshot().archived_bytes==MiB);
    archive.pause(true);CHECK(!refused.offload(source,0) && source==expected);archive.pause(false);
    first.reset();archive.maintain();active=nullptr;
}
void persistence_failures(const std::string& directory){
    using Fault=neostation::storage::Store::Fault;
    for(auto fault:{Fault::write_error,Fault::sync_error,Fault::read_error,Fault::corrupt,Fault::truncate}){
        Archive archive(directory,3,config());active=&archive;ColdSource owner;
        auto source=fixture(128*1024,81);const auto expected=source;
        CHECK(owner.offload(source,1));archive.inject(fault);archive.maintain();
        auto stats=archive.snapshot();CHECK(stats.archive_failures==1 && stats.staging_bytes==128*1024);
        CHECK(stats.last_errno==(fault==Fault::write_error?ENOSPC:fault==Fault::corrupt?EILSEQ:EIO));
        CHECK(stats.managed.logical_bytes==0 && stats.archived_bytes==0);
        std::string restored;int error=0;CHECK(owner.restore(restored,error)==NS_SOURCE_OK && restored==expected);
        owner.reset();archive.maintain();CHECK(archive.snapshot().staging_bytes==0);active=nullptr;
    }
    auto limits=config();limits.managed.logical_bytes=65536;
    Archive quota(directory,4,limits);active=&quota;ColdSource owner;
    auto source=fixture(128*1024,82);const auto expected=source;
    CHECK(owner.offload(source,0));quota.maintain();CHECK(quota.snapshot().archive_failures==1);
    std::string restored;int error=0;CHECK(owner.restore(restored,error)==NS_SOURCE_OK && restored==expected);
    owner.reset();quota.maintain();active=nullptr;
}
void restore_failures_and_epochs(const std::string& directory){
    using Fault=neostation::storage::Store::Fault;
    for(auto fault:{Fault::read_error,Fault::corrupt,Fault::truncate}){
        Archive archive(directory,5,config());active=&archive;ColdSource owner;
        auto source=fixture(128*1024,83);const auto expected=source;
        CHECK(owner.offload(source,2));archive.maintain();CHECK(archive.snapshot().staging_bytes==0);
        archive.inject(fault);std::string restored="old data";int error=0;
        CHECK(owner.restore(restored,error)==NS_SOURCE_IO && restored.empty());
        CHECK(error==(fault==Fault::corrupt?EILSEQ:EIO));
        if(fault==Fault::read_error)CHECK(owner.restore(restored,error)==NS_SOURCE_OK && restored==expected);
        active=nullptr;CHECK(owner.restore(restored,error)==NS_SOURCE_MISSING && restored.empty());
        active=&archive;owner.reset();archive.maintain();active=nullptr;
    }
}
}
int main(int argc,char** argv){
    CHECK(argc==2 && neostation::source_client::install(&api)==NS_SOURCE_OK);
    large_cycle(argv[1]);pressure_and_limits(argv[1]);persistence_failures(argv[1]);restore_failures_and_epochs(argv[1]);
    std::cout<<"{\"passed\":true,\"coreClientExecuted\":true,\"ramStorageRamCycleVerified\":true,"
        "\"byteIdentityVerified\":true,\"admissionNoDiskIO\":true,\"pressureAndQuotaVerified\":true,"
        "\"persistenceFailureRetainsSnapshot\":true,\"failedRestoreClearsOutput\":true,\"staleEpochRejected\":true,"
        "\"sharedRetirementVerified\":true,\"logicalTouchedBytes\":"<<cycle.archived_bytes<<
        ",\"restoredBytes\":"<<cycle.restored_bytes<<",\"coreReleasedCapacityBytes\":"<<cycle.core_released_capacity<<
        ",\"stagingPeakBytes\":"<<cycle.staging_peak<<",\"stagingLimitBytes\":"<<config().staging_bytes<<
        ",\"managedMappedPeakBytes\":"<<cycle.managed.resident_mapped_peak<<
        ",\"managedMappedLimitBytes\":"<<cycle.managed.resident_limit_bytes<<
        ",\"diskReadBytes\":"<<cycle.managed.store.bytes_read<<",\"diskWriteBytes\":"<<cycle.managed.store.bytes_written<<"}\n";
}
