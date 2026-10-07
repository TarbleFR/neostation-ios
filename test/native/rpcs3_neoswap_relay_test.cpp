#include "util/vm.hpp"
#include "ios/RPCS3IOSSharedMemory.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <set>
#include <thread>
#include <vector>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

namespace fs {
inline std::string get_cache_dir() { return "/tmp/"; }
inline void remove_file(const std::string& path) { ::unlink(path.c_str()); }
}
template<class T> T ensure(T value) { if (!value) std::abort(); return value; }
template<class T,class P> T ensure(T value,P predicate) { if (!predicate(value)) std::abort(); return value; }
#define FN(...) [](auto x) { return (__VA_ARGS__); }
namespace utils {
inline int operator+(protection value) {
 switch(value) {
 case protection::no: return PROT_NONE;
 case protection::ro: return PROT_READ;
 case protection::rw: return PROT_READ|PROT_WRITE;
 case protection::rx: return PROT_READ|PROT_EXEC;
 case protection::wx: return PROT_READ|PROT_WRITE|PROT_EXEC;
 }
 std::abort();
}
#include "ShmProduction.inc"
}
namespace {
constexpr std::size_t bytes=65536;
struct object { int file; std::size_t size; std::map<void*,bool> aliases; bool retiring=false; std::set<void*> quarantined{}; };
std::map<std::uint64_t,object> objects;
std::uint64_t serial=0;
int creates=0, releases=0, maps=0, unmaps=0;
bool active=true, reject_create=false, reject_map=false, reject_release=false;
int reject_unmap=0, retire_calls=0;
std::mutex broker_mutex;
void* reserve(std::size_t size) {
 void* raw=mmap(nullptr,size+bytes,PROT_NONE,MAP_ANON|MAP_PRIVATE,-1,0);
 assert(raw!=MAP_FAILED);
 const auto start=reinterpret_cast<std::uintptr_t>(raw);
 const auto aligned=(start+bytes-1)&~(bytes-1);
 if(aligned>start) assert(munmap(raw,aligned-start)==0);
 if(aligned<start+bytes) assert(munmap(reinterpret_cast<void*>(aligned+size),start+bytes-aligned)==0);
 return reinterpret_cast<void*>(aligned);
}
int create(std::uint32_t owner,std::uint64_t size,std::uint64_t* token) {
 std::lock_guard lock(broker_mutex);
 ++creates; assert(owner==0); *token=0;
 if(reject_create) return NEOSWAP_RELAY_QUOTA;
 int file=rpcs3::ios::create_shared_memory_file("/tmp/",size); assert(file>=0);
 *token=++serial; objects.emplace(*token,object{file,size,{}}); return NEOSWAP_RELAY_OK;
}
int map(std::uint64_t token,void* target,std::uint32_t protection,void** result) {
 std::lock_guard lock(broker_mutex); ++maps; *result=nullptr;
 if(reject_map) return NEOSWAP_RELAY_MAPPING;
 auto& obj=objects.at(token); if(obj.retiring) return NEOSWAP_RELAY_BUSY; bool fixed=target!=nullptr;
 if(!target) target=reserve(obj.size);
 int flags=protection==NEOSWAP_RELAY_NONE?PROT_NONE:PROT_READ;
 if(protection==NEOSWAP_RELAY_READ_WRITE) flags|=PROT_WRITE;
 void* mapped=mmap(target,obj.size,flags,MAP_FIXED|MAP_SHARED,obj.file,0); assert(mapped==target);
 assert(obj.aliases.emplace(mapped,fixed).second); *result=mapped; return NEOSWAP_RELAY_OK;
}
int unmap(std::uint64_t token,void* address) {
 std::lock_guard lock(broker_mutex); ++unmaps;
 auto& obj=objects.at(token); auto it=obj.aliases.find(address); assert(it!=obj.aliases.end());
 if(reject_unmap>0) { --reject_unmap; return NEOSWAP_RELAY_MAPPING; }
 if(it->second) assert(mmap(address,obj.size,PROT_NONE,MAP_FIXED|MAP_ANON|MAP_PRIVATE,-1,0)==address);
 else assert(munmap(address,obj.size)==0);
 obj.aliases.erase(it); return NEOSWAP_RELAY_OK;
}
int release(std::uint64_t token) {
 std::lock_guard lock(broker_mutex); auto it=objects.find(token); assert(it!=objects.end());
 if(!it->second.aliases.empty()) return NEOSWAP_RELAY_BUSY;
 if(reject_release) return NEOSWAP_RELAY_CLEANUP;
 assert(close(it->second.file)==0); objects.erase(it); ++releases; return NEOSWAP_RELAY_OK;
}
int retire(std::uint64_t token) {
 std::vector<std::pair<void*,bool>> aliases;
 {
  std::lock_guard lock(broker_mutex); ++retire_calls;
  auto& obj=objects.at(token); obj.retiring=true;
  for(const auto& item:obj.aliases) if(!obj.quarantined.count(item.first)) aliases.push_back(item);
 }
 for(const auto& item:aliases) {
  const int result=unmap(token,item.first);
  if(result!=NEOSWAP_RELAY_OK && item.second) {
   // After retire returns, callers may reuse their fixed ranges. Never retry
   // an overwrite there; retain the backing instead of touching new memory.
   std::lock_guard lock(broker_mutex); objects.at(token).quarantined.insert(item.first);
  }
 }
 return release(token);
}
void collect() {
 std::vector<std::uint64_t> pending;
 { std::lock_guard lock(broker_mutex); for(const auto& item:objects) if(item.second.retiring) pending.push_back(item.first); }
 for(auto token:pending) (void)retire(token);
}
int enabled(std::uint32_t owner) { assert(owner==0); return active; }
int snapshot(NeoSwapRelayStats*) { return NEOSWAP_RELAY_OK; }
const NeoSwapRelayAPI api={sizeof(api),NEOSWAP_RELAY_ABI,create,map,unmap,release,enabled,snapshot,retire};
void fault(void* pointer,bool write) {
 const pid_t child=fork(); assert(child>=0);
 if(!child) { volatile unsigned char* p=static_cast<unsigned char*>(pointer); if(write) *p=0x55; else { const auto v=*p;(void)v; } _exit(0); }
 int status=0; assert(waitpid(child,&status,0)==child); assert(WIFSIGNALED(status));
}
void fallback(bool cow,utils::protection protection=utils::protection::rw) {
 void* first=reserve(bytes); void* second=reserve(bytes);
 { utils::shm memory(bytes,0,utils::shm_use::guest_data);
   assert(memory.map_critical(first,protection,cow).first==first);
   assert(memory.map_critical(second,protection,cow).first==second);
   if(protection==utils::protection::rw) {
    static_cast<unsigned char*>(first)[0]=0x48;
    if(!cow) assert(static_cast<unsigned char*>(second)[0]==0x48);
   }
   memory.unmap_critical(first); memory.unmap_critical(second);
 }
 assert(munmap(first,bytes)==0); assert(munmap(second,bytes)==0);
}
}
int main() {
 assert(neostation::relay::install(nullptr)==NEOSWAP_RELAY_INVALID);
 fallback(false); assert(creates==0); // no host API: ordinary file views
 auto invalid=api; invalid.struct_size=0;
 assert(neostation::relay::install(&invalid)==NEOSWAP_RELAY_INVALID);
 invalid=api; invalid.unmap=nullptr;
 assert(neostation::relay::install(&invalid)==NEOSWAP_RELAY_INVALID);
 invalid=api; invalid.retire=nullptr;
 assert(neostation::relay::install(&invalid)==NEOSWAP_RELAY_INVALID);
 assert(neostation::relay::install(&api)==NEOSWAP_RELAY_OK);
 assert(neostation::relay::install(&api)==NEOSWAP_RELAY_OK);
 auto other=api; assert(neostation::relay::install(&other)==NEOSWAP_RELAY_BUSY);
 active=false; fallback(false); assert(creates==0); active=true;
 // Gameplay never requests a new relay loan. The entire original shm path
 // remains usable even if a relay manager holds its broker lock indefinitely.
 for (int cycle=0; cycle<3; ++cycle) {
  neostation::relay::set_gameplay_active(true);
  const int before_creates=creates, before_maps=maps;
  {
   std::lock_guard blocked(broker_mutex);
   fallback(false);
  }
  assert(creates==before_creates && maps==before_maps);
  assert(neostation::relay::gameplay_fallbacks.load()==static_cast<unsigned>(cycle+1));
  neostation::relay::set_gameplay_active(false);
  fallback(false); // next loading cycle can acquire a fresh relay object
  assert(creates==before_creates+1 && objects.empty());
 }
 const int boot_creates=creates;
 fallback(true); assert(creates==boot_creates); // COW excludes relay before any view
 fallback(false,utils::protection::rx); assert(creates==boot_creates); // executable excluded
 reject_create=true; fallback(false); assert(objects.empty()); reject_create=false;
 reject_map=true; fallback(false); assert(objects.empty()); reject_map=false;
 void* base=reserve(bytes); void* sudo=reserve(bytes);
 {
   // Actual preallocated main/video/stack constructor, not a test-only shim.
   utils::shm memory(bytes,std::string("_block_x00010000"),utils::shm_use::guest_data);
   assert(memory.map_critical(base,utils::protection::ro).first==base);
   neostation::relay::set_gameplay_active(true);
   // A boot-published object retains its shared relay backing in gameplay.
   assert(memory.map_critical(sudo).first==sudo);
   auto* self=memory.map_self(); assert(self);
   assert(objects.size()==1 && objects.begin()->second.aliases.size()==3);
   self[0]=0x39; self[bytes-1]=0x71;
   assert(static_cast<unsigned char*>(base)[0]==0x39);
   assert(static_cast<unsigned char*>(sudo)[bytes-1]==0x71);
   fault(base,true); // read-only view is independently protected
   memory.unmap_critical(base); fault(base,false);
   assert(objects.begin()->second.aliases.size()==2 && self[0]==0x39);
   assert(memory.map_critical(base,utils::protection::no).first==base); fault(base,false);
   assert(mprotect(base,bytes,PROT_READ)==0);
   assert(static_cast<unsigned char*>(base)[0]==0x39); // same backing after re-map
   // Later failure cannot switch to an empty file while other aliases are live.
   void* failing=reserve(bytes); reject_map=true;
   assert(memory.map_critical(failing).first==nullptr); fault(failing,false);
   assert(memory.map(failing,utils::protection::rx)==nullptr);
   assert(memory.map(failing,utils::protection::rw,true)==nullptr);
   assert(self[0]==0x39); reject_map=false; assert(munmap(failing,bytes)==0);
   memory.unmap_critical(base); memory.unmap_critical(sudo);
   fault(base,false); fault(sudo,false);
   assert(objects.begin()->second.aliases.size()==1);
   memory.unmap_self(); assert(objects.begin()->second.aliases.empty());
 }
 assert(objects.empty()); assert(munmap(base,bytes)==0); assert(munmap(sudo,bytes)==0);
 neostation::relay::set_gameplay_active(false);
 {
  utils::shm memory(bytes,0,utils::shm_use::guest_data);
  std::vector<std::thread> threads; std::vector<void*> views(8);
  for(std::size_t i=0;i<views.size();++i) threads.emplace_back([&,i]{views[i]=memory.map_self();});
  for(auto& thread:threads) thread.join();
  for(auto* view:views) assert(view==views[0]);
  assert(objects.size()==1 && objects.begin()->second.aliases.size()==1);
  assert(static_cast<unsigned char*>(views[0])[0]==0); // new object clears data
 }
 assert(objects.empty());
 // A failed second alias may unwind a block constructor before its normal
 // explicit unmap path. The actual shm destructor must retire its first view.
 base=reserve(bytes); sudo=reserve(bytes);
 {
  utils::shm memory(bytes,std::string("_block_xc0000000"),utils::shm_use::guest_data);
  assert(memory.map_critical(base).first==base);
  reject_map=true; assert(memory.map_critical(sudo).first==nullptr); reject_map=false;
 }
 assert(objects.empty()); fault(base,false); fault(sudo,false);
 assert(munmap(base,bytes)==0); assert(munmap(sudo,bytes)==0);
 // Failed fixed retirement is quarantined permanently: the caller can
 // reuse its reservation after destruction, so a later overwrite is unsafe.
 base=reserve(bytes); sudo=reserve(bytes);
 std::uint64_t retired_token=0;
 {
  utils::shm memory(bytes,0,utils::shm_use::guest_data);
  assert(memory.map_critical(base).first==base);
  assert(memory.map_critical(sudo).first==sudo);
  assert(memory.map_self()); retired_token=serial;
  reject_unmap=3;
 }
 assert(objects.size()==1 && objects.at(retired_token).retiring);
 assert(objects.at(retired_token).aliases.size()==3);
 assert(objects.at(retired_token).quarantined.size()==2);
 void* rejected=nullptr;
 assert(map(retired_token,nullptr,NEOSWAP_RELAY_READ_WRITE,&rejected)==NEOSWAP_RELAY_BUSY);
 assert(!rejected);
 // Simulate the next guest using ordinary file/anonymous fallback in its
 // persistent reservation. Maintenance MUST preserve these replacement bytes.
 assert(mmap(base,bytes,PROT_READ|PROT_WRITE,MAP_FIXED|MAP_ANON|MAP_PRIVATE,-1,0)==base);
 assert(mmap(sudo,bytes,PROT_READ|PROT_WRITE,MAP_FIXED|MAP_ANON|MAP_PRIVATE,-1,0)==sudo);
 static_cast<unsigned char*>(base)[0]=0x63;
 static_cast<unsigned char*>(sudo)[0]=0x85;
 collect(); collect();
 assert(objects.size()==1 && objects.at(retired_token).aliases.size()==2);
 assert(objects.at(retired_token).quarantined.size()==2);
 assert(static_cast<unsigned char*>(base)[0]==0x63);
 assert(static_cast<unsigned char*>(sudo)[0]==0x85);
 assert(munmap(base,bytes)==0); assert(munmap(sudo,bytes)==0);
 // End-of-process fixture cleanup; production retains these rights/accounting
 // until process exit rather than pretending quarantined capacity is free.
 assert(close(objects.at(retired_token).file)==0); objects.erase(retired_token);
 // Anywhere aliases are broker-owned and remain unavailable to the OS until
 // their successful unmap. They and final scrubbing can be retried safely.
 {
  utils::shm memory(bytes,0,utils::shm_use::guest_data);
  assert(memory.map_self()); retired_token=serial; reject_unmap=1;
 }
 assert(objects.size()==1 && objects.at(retired_token).aliases.size()==1);
 assert(objects.at(retired_token).quarantined.empty());
 reject_release=true; collect();
 assert(objects.size()==1 && objects.at(retired_token).aliases.empty());
 reject_release=false; collect(); assert(objects.empty());
 assert(retire_calls>=5);
 { utils::shm general(bytes); const int before=creates; assert(general.map_self()); assert(creates==before); }
 std::printf("PASS relay shm: creates=%d maps=%d unmaps=%d releases=%d normal_live=0; fixed_failure_quarantine=2 until process exit; coherent fixed/self aliases, protection, fallback, concurrent map_self, relaunch\n",creates,maps,unmaps,releases);
}
