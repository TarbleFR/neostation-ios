// SPDX-License-Identifier: MIT
#include "SourceArchive.h"
#include "NeoSwapExperiment.h"
#include "NeoSwapSourceWork.h"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <vector>
using namespace neostation;

int main(int argc,char** argv){
    assert(argc==2);
    const auto baseline=experiment::parse("baseline"),relay=experiment::parse("relay"),
        integrated=experiment::parse("integrated"),invalid=experiment::parse("INTEGRATED");
    assert(!baseline.relay()&&!baseline.donors()&&!baseline.storage()&&baseline.configured);
    assert(relay.relay()&&!relay.donors()&&!relay.storage());
    assert(integrated.relay()&&integrated.donors()&&integrated.storage());
    assert(!invalid.valid&&!invalid.relay()&&!invalid.donors());
    assert(!experiment::parse("").valid&&!experiment::parse(nullptr).configured);
    source_work::VideoMemoryNeed need;
    need.update(600ULL<<20,true,false,4ULL<<30);assert(!need.needed());
    need.update(500ULL<<20,true,false,4ULL<<30);assert(need.needed());
    assert(need.enter_threshold()==512ULL<<20&&need.leave_threshold()==768ULL<<20);
    need.update(700ULL<<20,true,false,4ULL<<30);assert(need.needed());
    need.update(800ULL<<20,true,false,4ULL<<30);assert(!need.needed());
    need.update(2ULL<<30,true,false,16ULL<<30);assert(need.enter_threshold()==1ULL<<30);
    need.update(0,false,false);assert(!need.needed()&&!std::strcmp(need.reason(),"available_memory_unknown"));

    source_archive::Config config;config.managed.store.compression=false;
    source_archive::Archive archive(argv[1],71,config);
    std::vector<char> input(128*1024),output(input.size());
    for(size_t i=0;i<input.size();++i)input[i]=static_cast<char>((i*17)^(i>>8));
    const auto admission=archive.admit(2,input.data(),input.size());assert(admission.code==NS_SOURCE_OK);
    auto batch=archive.drain_operations();assert(batch.count==1&&batch.events[0].operation==source_archive::Operation::admitted);
    assert(batch.events[0].session==71&&batch.events[0].object==admission.object&&batch.events[0].bytes==input.size());
    assert(archive.try_read_staging(admission.object,output.data(),output.size())==NS_SOURCE_OK&&output==input);
    archive.maintain();int error=0;
    assert(archive.snapshot().staging_bytes==0);
    assert(archive.read(admission.object,output.data(),output.size(),error)==NS_SOURCE_OK&&output==input);
    batch=archive.drain_operations();unsigned checkpoints=0;bool unmapped=false,restored=false,ram=false;
    uint64_t sequence=1;
    for(size_t i=0;i<batch.count;++i){const auto& e=batch.events[i];
        assert(e.sequence>sequence&&e.object==admission.object&&e.monotonic_us>0);sequence=e.sequence;
        checkpoints+=e.operation==source_archive::Operation::checkpoint;
        unmapped|=e.operation==source_archive::Operation::archived;
        restored|=e.operation==source_archive::Operation::restored;ram|=e.operation==source_archive::Operation::ram_read;
    }
    assert(checkpoints==2&&unmapped&&restored&&ram);
    archive.discard(admission.object);archive.maintain();assert(archive.snapshot().sources==0);

    source_archive::Archive failed(argv[1],72,config);
    const auto retained=failed.admit(1,input.data(),input.size());assert(retained.code==NS_SOURCE_OK);
    failed.inject(storage::Store::Fault::write_error);failed.maintain();
    assert(failed.try_read_staging(retained.object,output.data(),output.size())==NS_SOURCE_OK&&output==input);
    batch=failed.drain_operations();bool preserved=false;
    for(size_t i=0;i<batch.count;++i)if(batch.events[i].operation==source_archive::Operation::archive_failed){
        assert(batch.events[i].os_error==ENOSPC&&batch.events[i].result==NS_SOURCE_IO);preserved=true;
    }
    assert(preserved&&failed.snapshot().staging_bytes==input.size());
    for(unsigned i=0;i<600;++i)assert(failed.try_read_staging(retained.object,output.data(),output.size())==NS_SOURCE_OK);
    batch=failed.drain_operations();assert(batch.count==64&&batch.dropped==88&&batch.pending==448);
    sequence=batch.events[0].sequence;
    for(size_t i=1;i<batch.count;++i)assert(batch.events[i].sequence==sequence+i);
    std::cout<<"{\"passed\":true,\"profilesIsolated\":true,\"adaptiveHeadroomVerified\":true,"
        "\"actualArchiveJournalVerified\":true,\"failedWriteRetainsBytesAndErrno\":true,"
        "\"boundedJournalReportsGaps\":true,\"physicalIPhoneValidated\":false}\n";
}
