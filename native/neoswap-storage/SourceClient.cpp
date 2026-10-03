// SPDX-License-Identifier: MIT
#include "SourceClient.h"
#include "FrameClient.h"
#include <algorithm>
#if !defined(__cpp_exceptions)
#error "NeoSwap SourceClient.cpp requires exceptions in this dedicated unit"
#endif
namespace neostation::source_client {
bool ColdSource::offload(std::string& source,uint32_t domain) noexcept {
    if(reference_ || source.empty())return false;
    const auto* api=installed.load();if(!api)return false;
    const auto session=api->session();if(!session)return false;
    try {
        auto ref=std::make_shared<Reference>(); // Before host ownership transfer.
        ref->api=api;ref->session=session;ref->bytes=source.size();
        uint64_t object=0;
        if(api->admit(session,domain,source.data(),source.size(),&object)!=NS_SOURCE_OK || !object)
            return false;
        ref->object=object;reference_=std::move(ref);
        const auto capacity=source.capacity();std::string().swap(source);
        api->released(session,capacity);
        return true;
    }catch(...){return false;}
}
int ColdSource::restore(std::string& output,int& os_error) const noexcept {
    os_error=0;output.clear();if(!reference_)return NS_SOURCE_MISSING;
    const auto& ref=*reference_;
    try {
        output.resize(static_cast<size_t>(ref.bytes));
        const auto result=ref.api->read(ref.session,ref.object,output.data(),ref.bytes,&os_error);
        if(result!=NS_SOURCE_OK)output.clear();
        return result;
    }catch(...){output.clear();return NS_SOURCE_BUSY;}
}
bool ColdFrame::offload(const char* pixels, size_t bytes) noexcept {
    if(reference_ || !pixels || bytes < 4096 || bytes > frame_max_bytes)return false;
    const auto* api=installed.load();if(!api)return false;
    const auto epoch=api->session();if(!epoch)return false;
    try {
        auto candidate=std::make_shared<FrameReference>();
        candidate->bytes=bytes;
        candidate->count=static_cast<uint32_t>((bytes+NEOSWAP_SOURCE_MAX_BYTES-1)/NEOSWAP_SOURCE_MAX_BYTES);
        const auto chunk=(bytes+candidate->count-1)/candidate->count;
        size_t offset=0;
        for(uint32_t index=0;index<candidate->count;++index){
            auto& ref=candidate->chunks[index];
            ref.api=api;ref.session=epoch;ref.bytes=std::min(chunk,bytes-offset);
            if(api->admit(epoch,frame_domain,pixels+offset,ref.bytes,&ref.object)!=NS_SOURCE_OK || !ref.object)
                return false; // candidate retires ALL accepted chunks exactly once
            offset+=static_cast<size_t>(ref.bytes);
        }
        // A concurrent stop/relaunch must never strand the original frame in
        // a retired epoch. Old hosts reject domain 3 and keep the RAM fallback.
        if(api->session()!=epoch)return false;
        reference_=std::move(candidate);return true;
    }catch(...){return false;}
}
bool ColdFrame::offload_copy(size_t bytes,PixelCopy copy,void* context) noexcept {
    const auto* api=installed.load();
    if(reference_ || !copy || bytes<4096 || bytes>frame_max_bytes || !api || !api->session())return false;
    try {
        std::string packed(bytes,'\0');
        if(copy(packed.data(),bytes,context)!=static_cast<int>(bytes))return false;
        return offload(packed.data(),packed.size());
    }catch(...){return false;}
}
int ColdFrame::restore(std::string& output,int& os_error) const noexcept {
    os_error=0;output.clear();if(!reference_)return NS_SOURCE_MISSING;
    const auto& frame=*reference_;
    try {
        output.resize(static_cast<size_t>(frame.bytes));size_t offset=0;
        for(uint32_t index=0;index<frame.count;++index){
            const auto& ref=frame.chunks[index];
            const int code=ref.api->read(ref.session,ref.object,output.data()+offset,ref.bytes,&os_error);
            if(code!=NS_SOURCE_OK){output.clear();return code;}
            offset+=static_cast<size_t>(ref.bytes);
        }
        return NS_SOURCE_OK;
    }catch(...){output.clear();return NS_SOURCE_BUSY;}
}
}
