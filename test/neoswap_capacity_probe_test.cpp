#include "NeoSwapCapacityProbe.h"
#include <cassert>
#include <cstdlib>
#include <string>
#include <vector>
#include <unistd.h>
#ifdef __APPLE__
#include <mach/mach.h>
#endif
int main(int argc,char** argv){
  bool full=argc==2 && std::string(argv[1])=="--full";
  constexpr uint64_t MiB=1024*1024;char folder[]="/tmp/neoswap-capacity-XXXXXX";assert(mkdtemp(folder));
  NeoSwapConfig config{sizeof(config),1,8192*MiB,0,MiB,1u<<NEOSWAP_PROBE,0};
  assert(NeoSwap_Configure(folder,&config)==0);
  config.capacity_bytes=8192*MiB+1;assert(NeoSwap_Configure(folder,&config)==NEOSWAP_INVALID);config.capacity_bytes=8192*MiB;
  std::vector<std::string> phases;uint64_t footprintBefore=0,footprintPeak=0;
  auto sample=[&](const char* phase,uint64_t){phases.emplace_back(phase);
#ifdef __APPLE__
    task_vm_info_data_t info{};mach_msg_type_number_t count=TASK_VM_INFO_COUNT;
    if(task_info(mach_task_self(),TASK_VM_INFO,reinterpret_cast<task_info_t>(&info),&count)==KERN_SUCCESS){
      if(phases.size()==1)footprintBefore=info.phys_footprint;footprintPeak=std::max<uint64_t>(footprintPeak,info.phys_footprint);
    }
#endif
  };
  assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),64*MiB,sample,[]{return true;})==0);
  assert((phases==std::vector<std::string>{"before","written","synced","verified","released"}));
  NeoSwapStats stats{};stats.struct_size=sizeof(stats);assert(NeoSwap_Snapshot(&stats)==0 && !stats.live_blocks && stats.owners[NEOSWAP_PROBE].allocation_count==1);
  assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),64*MiB,sample,[]{return false;})==NEOSWAP_BUSY);
  int headroomCalls=0;
  assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),64*MiB,sample,[&]{return ++headroomCalls<3;})==NEOSWAP_BUSY);
  assert(NeoSwap_Snapshot(&stats)==0 && !stats.live_blocks);
  NeoSwap_TestFailNext(5);assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),64*MiB,sample,[]{return true;})==NEOSWAP_IO);
  assert(NeoSwap_Snapshot(&stats)==0 && !stats.live_blocks);
  assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),8192*MiB+1,sample,[]{return true;})==NEOSWAP_INVALID);
  if(full){
    config.minimum_free_bytes=2048*MiB;assert(NeoSwap_Configure(folder,&config)==0);
    phases.clear();footprintBefore=0;footprintPeak=0;
    assert(NeoSwapCapacityProbe(NeoSwap_GetAPI(1),8192*MiB,sample,[]{return true;})==0);
    assert(NeoSwap_Snapshot(&stats)==0 && !stats.live_blocks && stats.peak_bytes==8192*MiB);
    printf("{\"platform\":\"macOS host\",\"verifiedBytes\":8589934592,\"footprintBefore\":%llu,\"footprintPeak\":%llu,\"realIPhoneValidated\":false}\n",(unsigned long long)footprintBefore,(unsigned long long)footprintPeak);
  }
  config.capacity_bytes=0;assert(NeoSwap_Configure(nullptr,&config)==0);assert(rmdir(folder)==0);
  puts("PASS: 8GiB budget accepted, >8GiB rejected; 64MiB file data synced/reloaded/verified; pressure and I/O failure release all owned blocks. No iPhone8GiB claim.");
}
