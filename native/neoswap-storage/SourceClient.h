// SPDX-License-Identifier: MIT
#pragma once
#include "SourceABI.h"
#include <atomic>
#include <memory>
#include <string>
#include <utility>
namespace neostation::source_client {
inline constinit std::atomic<const NeoSwapSourceAPI*> installed{nullptr};
inline int install(const NeoSwapSourceAPI* api) noexcept {
    if(!api || api->struct_size!=sizeof(*api) || api->abi_version!=NEOSWAP_SOURCE_ABI ||
       !api->session || !api->admit || !api->read || !api->discard || !api->released)
        return NS_SOURCE_INVALID;
    const NeoSwapSourceAPI* expected=nullptr;
    return installed.compare_exchange_strong(expected,api)||expected==api ? NS_SOURCE_OK:NS_SOURCE_INVALID;
}
struct Reference final {
    const NeoSwapSourceAPI* api=nullptr;
    uint64_t session=0,object=0,bytes=0;
    ~Reference(){if(api && object)api->discard(session,object);}
};
// Shared ownership preserves shader moves/copies without double retirement.
// A restored string owns its bytes; no reference escapes a temporary lease.
class ColdSource final {
public:
    void reset() noexcept { reference_.reset(); }
    bool archived() const noexcept { return bool(reference_); }
    bool offload(std::string& source,uint32_t domain) noexcept {
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
    int restore(std::string& output,int& os_error) const noexcept {
        os_error=0;output.clear();if(!reference_)return NS_SOURCE_MISSING;
        const auto& ref=*reference_;
        try {
            output.resize(static_cast<size_t>(ref.bytes));
            const auto result=ref.api->read(ref.session,ref.object,output.data(),ref.bytes,&os_error);
            if(result!=NS_SOURCE_OK)output.clear();
            return result;
        }catch(...){output.clear();return NS_SOURCE_BUSY;}
    }
private:
    std::shared_ptr<Reference> reference_;
};
}
