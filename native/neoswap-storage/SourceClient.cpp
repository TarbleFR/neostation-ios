// SPDX-License-Identifier: MIT
#include "SourceClient.h"
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
}
