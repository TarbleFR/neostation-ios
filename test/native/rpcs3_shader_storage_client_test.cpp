// SPDX-License-Identifier: MIT
#include "ios/NeoSwapStorage/ShaderKey.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <iomanip>
#include <sstream>
using namespace neostation::storage_client;
void mbedtls_zeroize(void* v,size_t n){volatile auto* p=static_cast<volatile uint8_t*>(v);while(n--)*p++=0;}
static uint64_t epoch=5;static bool hit=false,reject=false;static unsigned releases=0,publications=0,invalidations=0;
static std::vector<uint32_t> payload{0x07230203,0x00010500,0,32,0,123,456,789};
uint64_t session(){return epoch;}
int acquire(uint64_t s,const uint8_t*,NeoSwapStorageView* view){*view={};if(!hit||s!=epoch)return NS_STORAGE_MISS;view->words=payload.data();view->byte_count=payload.size()*4;view->lease=&payload;return NS_STORAGE_OK;}
int publish(uint64_t s,const uint8_t*,const uint32_t* p,uint64_t n){assert(s==epoch);++publications;assert(n==payload.size()*4&&!std::memcmp(p,payload.data(),n));return reject?NS_STORAGE_BUSY:NS_STORAGE_OK;}
void release(NeoSwapStorageView* v){assert(v->lease==&payload);*v={};++releases;}
void prefetch(uint64_t,const uint8_t*){}
void invalidate(uint64_t,const uint8_t*){++invalidations;}
void event(uint64_t,uint32_t,uint64_t){}
int main(){
    NeoSwapStorageAPI bad{};assert(install(&bad)==NS_STORAGE_INVALID);
    static const NeoSwapStorageAPI api{sizeof(api),1,session,acquire,publish,release,prefetch,invalidate,event};
    assert(install(&api)==0&&install(&api)==0);
    auto t=shader_ticket("test shader",2);std::ostringstream hex;for(auto b:t.key)hex<<std::hex<<std::setfill('0')<<std::setw(2)<<unsigned(b);
    assert(hex.str()=="EXPECTED_KEY_HEX");assert(shader_ticket("test shader",1).key!=t.key);assert(shader_ticket("changed shader",2).key!=t.key);
    std::vector<uint32_t> original;unsigned builds=0,calls=0;
    auto build=[&](auto& data){++builds;data=payload;return true;};
    auto create=[&](auto* p,size_t n){++calls;assert(n==payload.size()*4&&!std::memcmp(p,payload.data(),n));return ModuleResult::ok;};
    assert(compile(t,original,build,create)==CompileResult::ok);assert(builds==1&&publications==1&&original.empty());
    hit=true;assert(compile(t,original,build,create)==CompileResult::ok);assert(builds==1&&calls==2&&releases==1);
    assert(compile(t,original,build,[](auto*,size_t){return ModuleResult::fatal;})==CompileResult::module_failure);assert(builds==1&&releases==2);
    unsigned tries=0;assert(compile(t,original,build,[&](auto*,size_t){return ++tries==1?ModuleResult::retry_source:ModuleResult::ok;})==CompileResult::ok);assert(builds==2&&tries==2&&invalidations==1);
    hit=false;reject=true;assert(compile(t,original,build,create)==CompileResult::ok&&original==payload);
    const auto prior=publications;++epoch;assert(compile(t,original,build,create)==CompileResult::ok&&publications==prior&&original==payload);
    std::cout<<"PASS production shader client: SHA-256 namespace, cache hit pin, OOM no retry, cache-rejection rebuild, admission fallback and stale-session isolation\n";
}
