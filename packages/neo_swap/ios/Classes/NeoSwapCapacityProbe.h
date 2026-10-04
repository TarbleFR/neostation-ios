// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "NeoSwap.h"
#include <array>
#include <algorithm>
#include <cstring>
#include <sys/mman.h>

// A Simulator process is hosted by macOS and may have no managed iOS memory
// limit. Its zero os_proc_available_memory result is not device headroom.
// Device zero stays a refusal; the Simulator exercises file integrity only.
inline bool NeoSwapCapacityHeadroom(uint64_t available,bool simulator) {
  return simulator || available>256ULL*1024*1024;
}

// A real file-backed capacity exercise, separate from game allocations. Each
// block is synced before asking the OS to discard its clean resident pages.
// MADV_DONTNEED is only a hint; never report it as bytes physically saved.
template<class Sample,class Headroom>
int NeoSwapCapacityProbe(const NeoSwapAPI* api,uint64_t size,Sample sample,Headroom headroom) {
  constexpr uint64_t MiB=1024*1024,blockSize=256*MiB,chunkSize=65536;
  if(!api || !size || size>8192*MiB || size%chunkSize)return NEOSWAP_INVALID;
  std::array<void*,32> blocks{};std::array<uint64_t,32> lengths{};
  std::array<unsigned char,chunkSize> expected{};int result=NEOSWAP_OK;size_t count=0;
  sample("before",0);
  for(uint64_t offset=0;offset<size && result==NEOSWAP_OK;offset+=blockSize) {
    if(!headroom()){result=NEOSWAP_BUSY;break;}
    uint64_t length=std::min<uint64_t>(blockSize,size-offset);void* address=nullptr;
    result=api->allocate(NEOSWAP_RPCS3,NEOSWAP_CPU_DATA,length,chunkSize,&address);if(result!=NEOSWAP_OK)break;
    blocks[count]=address;lengths[count++]=length;
    for(uint64_t at=0;at<length;at+=chunkSize) {
      if(at%(8*MiB)==0 && !headroom()){result=NEOSWAP_BUSY;break;}
      for(size_t i=0;i<expected.size();++i)expected[i]=static_cast<unsigned char>((i*131)^((offset+at)/chunkSize)*17^0x9d);
      std::memcpy(static_cast<char*>(address)+at,expected.data(),expected.size());
    }
    sample("written",offset+length);
    if(result!=NEOSWAP_OK)break;
    result=api->sync(address);if(result!=NEOSWAP_OK)break;
    (void)::madvise(address,length,MADV_DONTNEED);sample("synced",offset+length);
  }
  if(result==NEOSWAP_OK)for(size_t b=0;b<count && result==NEOSWAP_OK;++b) {
    const auto* data=static_cast<unsigned char*>(blocks[b]);
    for(uint64_t at=0;at<lengths[b];at+=chunkSize) {
      if(at%(8*MiB)==0 && !headroom()){result=NEOSWAP_BUSY;break;}
      for(size_t i=0;i<expected.size();++i)expected[i]=static_cast<unsigned char>((i*131)^((b*blockSize+at)/chunkSize)*17^0x9d);
      if(std::memcmp(data+at,expected.data(),expected.size())){result=NEOSWAP_IO;break;}
      if(at%(8*MiB)==0 && at)(void)::madvise(const_cast<unsigned char*>(data)+at-8*MiB,8*MiB,MADV_DONTNEED);
    }
    sample("verified",b*blockSize+lengths[b]);
  }
  for(size_t b=0;b<count;++b){int released=api->release(blocks[b]);if(released!=NEOSWAP_OK)result=released;}
  sample("released",size);return result;
}
