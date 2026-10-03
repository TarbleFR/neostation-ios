// SPDX-License-Identifier: MIT
#include "ios/NeoSwapStorage/SourceClient.h"
#include <cassert>
#include <cerrno>
#include <cstring>
#include <iostream>
#include <map>
using namespace neostation::source_client;
namespace {
uint64_t epoch=1,next_id=1,released_bytes=0,discards=0;
int admit_result=NS_SOURCE_OK,read_result=NS_SOURCE_OK;
bool zero_object=false;
std::map<uint64_t,std::string> copies;
uint64_t session(){return epoch;}
int admit(uint64_t generation,uint32_t domain,const char* text,uint64_t bytes,uint64_t* object){
    assert(generation==epoch && domain<=2 && bytes && object);
    if(admit_result!=NS_SOURCE_OK)return admit_result;
    if(zero_object){*object=0;return NS_SOURCE_OK;}
    *object=next_id++;copies.emplace(*object,std::string(text,bytes));return NS_SOURCE_OK;
}
int read(uint64_t generation,uint64_t object,char* output,uint64_t bytes,int* error){
    if(generation!=epoch)return NS_SOURCE_MISSING;
    if(read_result!=NS_SOURCE_OK){std::memset(output,'?',bytes);*error=EIO;return read_result;}
    auto it=copies.find(object);if(it==copies.end())return NS_SOURCE_MISSING;
    assert(bytes==it->second.size());std::memcpy(output,it->second.data(),bytes);return NS_SOURCE_OK;
}
void discard(uint64_t,uint64_t object){++discards;copies.erase(object);}
void released(uint64_t generation,uint64_t bytes){assert(generation==epoch);released_bytes+=bytes;}
const NeoSwapSourceAPI api{sizeof(api),NEOSWAP_SOURCE_ABI,session,admit,read,discard,released};
}
int main(){
    ColdSource owner;std::string original(8192,'a');original[100]='\0';
    const auto expected=original;
    assert(!owner.offload(original,0) && original==expected);
    auto invalid=api;invalid.abi_version=2;assert(install(&invalid)==NS_SOURCE_INVALID);
    invalid=api;invalid.struct_size--;assert(install(&invalid)==NS_SOURCE_INVALID);
    invalid=api;invalid.read=nullptr;assert(install(&invalid)==NS_SOURCE_INVALID);
    assert(install(nullptr)==NS_SOURCE_INVALID && !installed.load());
    assert(install(&api)==NS_SOURCE_OK && install(&api)==NS_SOURCE_OK);
    auto competing=api;assert(install(&competing)==NS_SOURCE_INVALID);
    epoch=0;assert(!owner.offload(original,0) && original==expected);epoch=1;
    for(int refused:{NS_SOURCE_BUSY,NS_SOURCE_DISABLED,NS_SOURCE_INVALID,NS_SOURCE_IO,NS_SOURCE_QUOTA,NS_SOURCE_PRESSURE}){
        admit_result=refused;assert(!owner.offload(original,0) && original==expected && !owner.archived());
    }
    admit_result=NS_SOURCE_OK;zero_object=true;
    assert(!owner.offload(original,0) && original==expected);zero_object=false;
    const auto capacity=original.capacity();assert(owner.offload(original,2));
    assert(original.empty() && original.capacity()<capacity && released_bytes==capacity);
    assert(!owner.offload(original,0));
    auto shared=owner;auto moved=std::move(shared);owner.reset();
    assert(discards==0 && moved.archived());
    std::string restored;int error=-1;
    assert(moved.restore(restored,error)==NS_SOURCE_OK && restored==expected && error==0);
    restored[0]='b';assert(copies.begin()->second==expected);
    read_result=NS_SOURCE_IO;assert(moved.restore(restored,error)==NS_SOURCE_IO && restored.empty() && error==EIO);
    read_result=NS_SOURCE_OK;assert(moved.restore(restored,error)==NS_SOURCE_OK && restored==expected);
    epoch=2;assert(moved.restore(restored,error)==NS_SOURCE_MISSING && restored.empty());
    moved.reset();assert(discards==1 && copies.empty());
    assert(owner.restore(restored,error)==NS_SOURCE_MISSING && restored.empty());
    std::cout<<"PASS actual Core ColdSource: refusal retains source, accepted RAM snapshot, owning restore, shared retirement, stale epoch, cleared failed output\n";
}
