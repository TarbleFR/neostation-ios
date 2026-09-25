#include "GuestLanguageState.h"
#include <cassert>
#include <vector>
#include <iostream>
using namespace neokartpad;
static std::vector<uint8_t> ram(0x1800000, 0xA5);
uint8_t* ptr(uint32_t address, size_t size) {
  if (address < 0x80000000 || uint64_t(address - 0x80000000) + size > ram.size())
    throw std::runtime_error("unmapped test RAM");
  return ram.data() + address - 0x80000000;
}
int main() {
  GuestMemory mem{ptr};
  constexpr uint32_t sys=0x81000000, mgr=0x81001000, holders=0x81002000;
  mem.write32(kSystemManager, sys); mem.write32(sys+0x5c,1); mem.write32(sys+0x60,1);
  mem.write32(kArchiveManager,mgr); mem.write32(mgr+4,holders);
  for (size_t i=0;i<2;++i) {
    uint32_t h=0x81003000+i*0x1000, p=h+0x100, s=h+0x200;
    mem.write32(holders+(i?2:0)*4,h);mem.write32(h+0x10,p);mem.write32(p+4,s);
    auto* c=mem.at(h+8,2);c[0]=0;c[1]=2;
    std::memset(mem.at(s,128),0,128);std::memcpy(mem.at(s,128),"_E.szs",7);
  }
  const auto original=ram;
  for (uint32_t language=1;language<=6;++language) {
    const auto state=LanguageState::inspect(mem);
    state.apply(mem,language);
    assert(LanguageState::inspect(mem).matches(language));
    assert(mem.read32(sys+0x5c)==(language==6?1:language));
    state.rollback(mem);assert(ram==original);
  }
  for (uint32_t bad: {0u,7u,255u}) {
    bool threw=false;try{LanguageState::inspect(mem).apply(mem,bad);}catch(...){threw=true;}
    assert(threw);assert(ram==original);
  }
  mem.write32(kArchiveManager,0);const auto corrupt=ram;
  try { (void)LanguageState::inspect(mem);assert(false); } catch (...) {}
  assert(ram==corrupt);ram=original;
  for (int cycle=0;cycle<1000;++cycle) {
    SessionCommands command;
    const auto id=command.choose(3);assert(id);assert(!command.choose(4));
    assert(command.cancel(id));assert(!command.confirm(id));assert(command.selected==0);
    const auto newer=command.choose(3);assert(command.confirm(newer));
    command.accepted();assert(command.requestClose());assert(!command.requestClose());
    assert(!command.confirm(newer));assert(command.phase==SessionCommands::Phase::transitioning);
    command.complete();assert(command.phase==SessionCommands::Phase::closed);
    assert(!command.choose(2));
    SessionCommands normal;assert(normal.confirm(normal.choose(3)));
    normal.accepted();normal.complete();assert(normal.choose(4));normal.failed();assert(normal.choose(5));
  }
  std::cout << "PASS: real cache/suffix changes, rollback, invalid pointers/languages, 1000 consent/close cycles\n";
}
