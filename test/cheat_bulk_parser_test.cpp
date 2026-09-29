#include "NeoCheatDocument.h"
#include <cassert>
#include <iostream>
using namespace NeoCheat;
int main(){
 std::string plain,ini="[Gecko]\n",pnach,comments;
 for(int i=0;i<50;++i){
  const auto title="Cheat "+std::to_string(i);
  plain+=title+" [Author]\n04000000 00000001\n\n04000004 00000002\n\n";
  ini+="$"+title+" [Author]\n04000000 00000001\n04000004 00000002\n";
  pnach+="["+title+"]\nauthor=Author\npatch=1,EE,00000000,word,00000001\npatch=1,EE,00000004,word,00000002\n\n";
  comments+="// "+title+"\npatch=1,EE,00000000,word,00000001\n// inline note\npatch=1,EE,00000004,word,00000002\n\n";
 }
 for(const auto& [text,type]:std::vector<std::pair<std::string,std::string>>{{plain,"gecko"},{ini,"ini"},{pnach,"pnach"},{comments,"pnach"}}){
  auto r=parseDocument(text,type,"Filename");
  if(!r)std::cerr<<r.error<<" at "<<r.line<<"\n";
  assert(r && r.entries.size()==50);
  for(size_t i=0;i<50;++i){assert(r.entries[i].name=="Cheat "+std::to_string(i));assert(r.entries[i].lines.size()==2);}
 }
 auto ocarina=parseDocument("RMCP01\nMario Kart Wii\n\n"+plain,"gecko","file","","RMCP01");assert(ocarina && ocarina.entries.size()==50);
 assert(!parseDocument("RMCE01\nTitle\n\n"+plain,"gecko","file","","RMCP01"));
 for(const auto& title:{"Health","HEALTH","InfiniteLives"}){
  auto r=parseDocument(std::string(title)+"\n04000000 00000001","gecko","");assert(r && r.entries[0].name==title);
 }
 auto multilingual=parseDocument("Vie infinie [Émile]\n04000000 00000001\nAmmo\n04000004 00000002\n無限体力\n04000008 00000003","gecko","");
 assert(multilingual && multilingual.entries.size()==3 && multilingual.entries[0].creator=="Émile");
 std::string ar="Auto Aim [Nikra]\n6HUF-YY22-P0Y4N\n\nYP3X-W34H-8N8PU\n7663-4G9D-1BPQZ\n0WGZ-DYX8-MXNED\nGPPV-ZN8B-UVPUX\n\nSecond [Other]\n0123-4567-89ABC\n0123-4567-89ABD";
 auto encrypted=parseDocument(ar,"gecko","file");assert(encrypted && encrypted.entries.size()==2 && encrypted.entries[0].lines.size()==5 && encrypted.entries[0].encrypted);
 auto mixed=parseDocument("[Gecko]\n$A\n04000000 00000001\n[Gecko_Enabled]\n$A\n[Core]\nCPUThread=True\n[ActionReplay]\n$B\n0123-4567-89ABC","ini","");
 assert(mixed && mixed.entries.size()==2);
 for(auto bad:{"[Gecko]\n$A\n04000000 00000001\n$B\n04000004 XXXXXXXX","[Gecko]\n$Empty\n$A\n04000000 00000001","First\n04000000 00000001\n\nSecond\n04000004 XXXXXXXX","[Gecko]\n$Good\n04000000 00000001\n$Empty"}){
  auto r=parseDocument(bad,"gecko","file");assert(!r && r.entries.empty() && r.line>0);
 }
 auto invalid=parseDocument("First\n04000000 00000001\n\nBad\n04000004 XXXXXXXX\n\nGood\n04000008 00000003","gecko","");assert(!invalid && invalid.line==5);
 assert(!parseDocument("0123-4567-89ABC\n04000000 00000001","actionReplay","file"));
 auto raw=parseDocument("04000000 00000001\n\n04000004 00000002","gecko","File");assert(raw && raw.entries.size()==1 && raw.entries[0].lines.size()==2);
 assert(!parseDocument(std::string(262145,'x'),"gecko","file"));assert(!parseDocument(std::string("A\0B",3),"gecko","file"));
 std::string count;for(int i=0;i<513;++i)count+="$Code "+std::to_string(i)+"\n04000000 00000001\n";
 assert(!parseDocument(count,"gecko","file"));
 auto shortblock=parseDocument("[Gecko]\n$A\n04000000 00000001\n[Core]\nCPUThread=True\n","ini","file");assert(shortblock && shortblock.entries.size()==1);
 std::cout<<"PASS: 50 named multiline TXT/INI/PNACH entries; Ocarina identity; AR blocks; Unicode; whole-file rejection and limits\n";
}
