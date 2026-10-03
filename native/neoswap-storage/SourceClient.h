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
    // Definitions live in one exception-enabled unit. This header is also
    // included by RPCS3 units compiled with -fno-exceptions.
    bool offload(std::string& source,uint32_t domain) noexcept;
    int restore(std::string& output,int& os_error) const noexcept;
private:
    std::shared_ptr<Reference> reference_;
};
}
