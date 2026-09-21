#include "Rpcs3ArenaLayout.h"
#include <cassert>
#include <iostream>
#include <map>
using namespace neostation::rpcs3::arena;
struct Backend {
 std::map<uint64_t,uint64_t> live;
 uint64_t fail=0; int release_failure=0;
 bool cleanup_failed() const { return false; }
 int reserve(uint64_t a,uint64_t s) {
   if(a==fail) return 3;
   for(auto [p,n]:live) if(a<p+n && p<a+s) return 3;
   live[a]=s; return 0;
 }
 int release(uint64_t a,uint64_t s) {
   if(release_failure) return release_failure;
   assert(live.count(a)&&live[a]==s); live.erase(a); return 0;
 }
};
int main() {
 constexpr uint64_t page=16384;
 Backend b;
 auto r=reserve(std::vector<Range>{{low+page,low+page+budget_bytes}},page,b);
 assert(r.layout && r.layout.code==low+page && r.layout.data==low+page+code_bytes);
 assert(valid(r.layout,page)&&b.live.size()==1);
 assert(release(r.layout,b)==0 && b.live.empty());
 std::vector<Range> split{{low,low+code_bytes},{low+2*budget_bytes,low+2*budget_bytes+data_bytes}};
 auto s=reserve(split,page,b);
 assert(s.layout && !s.layout.contiguous && b.live.size()==2); release(s.layout,b);
 b.fail=split[1].begin;
 auto fail=reserve(split,page,b); assert(!fail.layout && fail.kernel==3 && b.live.empty());
 b.fail=0; auto recover=reserve(split,page,b); assert(recover.layout); release(recover.layout,b);
 b.fail=split[1].begin;b.release_failure=5;
 auto poison=reserve(split,page,b); assert(!poison.layout&&!poison.cleanup_ok);
 assert(!valid({low,low+page,false},page));
 assert(!valid({low,high-data_bytes,false},page));
 assert(candidates(split,3).empty());
 assert(candidates({{low,low+code_bytes},{low+reach,low+reach+data_bytes}},page).empty());
 assert(candidates({{low,low+code_bytes-1}},page).empty());
 // Simulate Core globals occupying a valid 1 GiB hole after dlopen: reserving
 // first keeps ownership; selecting after the occupancy no longer fits.
 auto before=candidates({{low,low+budget_bytes}},page);
 auto after=candidates({{low,low+code_bytes}},page);
 assert(before.size()==1&&after.empty());
 std::cout<<"PASS reservation: contiguous/split, page alignment, race, rollback, retry, reach, fixed448+576\n";
}
