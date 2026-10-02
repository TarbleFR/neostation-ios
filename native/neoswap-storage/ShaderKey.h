// SPDX-License-Identifier: MIT
#pragma once
#include "Client.h"
#include "Crypto/sha256.h"
#include <string_view>
namespace neostation::storage_client {
// Same-session SHA-256(source bytes, stage, compilation environment revision).
// SPIRVCommon: Vulkan 1.2, SPIR-V 1.5, optimizer disabled, optimizeSize=true.
inline Ticket shader_ticket(std::string_view source,uint32_t stage) noexcept {
    auto t=ticket();if(!active(t)||source.empty()||source.size()>4*1024*1024){t.session=0;return t;}
    const uint8_t prefix[16]={'N','S','-','S','P','V','1',0,
        uint8_t(stage),uint8_t(stage>>8),uint8_t(stage>>16),uint8_t(stage>>24),
        0,5,1,0};
    mbedtls_sha256_context ctx;mbedtls_sha256_init(&ctx);
    int rc=mbedtls_sha256_starts_ret(&ctx,0);
    if(!rc)rc=mbedtls_sha256_update_ret(&ctx,prefix,sizeof(prefix));
    if(!rc)rc=mbedtls_sha256_update_ret(&ctx,reinterpret_cast<const uint8_t*>(source.data()),source.size());
    if(!rc)rc=mbedtls_sha256_finish_ret(&ctx,t.key.data());
    mbedtls_sha256_free(&ctx);if(rc)t.session=0;
    return t;
}
}
