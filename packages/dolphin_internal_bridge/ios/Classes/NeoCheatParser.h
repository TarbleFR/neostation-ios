// SPDX-License-Identifier: GPL-3.0-or-later
// NeoStation manual cheat validation. No memory addresses are guessed or relocated.
#pragma once
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <sstream>
#include <string>
#include <vector>

namespace NeoCheat {
struct Entry { std::string name, creator, type; std::vector<std::string> lines, notes; bool encrypted=false; };
struct Result { std::vector<Entry> entries; std::string error; size_t line=0; explicit operator bool() const { return error.empty() && !entries.empty(); } };
inline std::string trim(std::string s) {
  const auto a=s.find_first_not_of(" \t\r\n");
  if(a==std::string::npos) return {};
  return s.substr(a,s.find_last_not_of(" \t\r\n")-a+1);
}
inline std::string upper(std::string s) { for(char& c:s) c=static_cast<char>(std::toupper(static_cast<unsigned char>(c))); return s; }
inline bool hex(const std::string& s, size_t min, size_t max) {
  return s.size()>=min && s.size()<=max && std::all_of(s.begin(),s.end(),[](unsigned char c){return std::isxdigit(c)!=0;});
}
inline bool safeName(const std::string& s) {
  return !trim(s).empty() && s.size()<=160 && s.find_first_of("\r\n[]$\0",0,6)==std::string::npos;
}
inline bool validId(const std::string& s) { return (s.size()==6 || s.size()==4) && std::all_of(s.begin(),s.end(),[](unsigned char c){return (c>='A' && c<='Z') || (c>='0' && c<='9');}); }
inline bool rawLine(const std::string& s, std::string* normalized) {
  std::istringstream in(s); std::string a,b,extra;
  if(!(in>>a>>b) || (in>>extra) || !hex(a,8,8) || !hex(b,8,8)) return false;
  *normalized=upper(a)+" "+upper(b); return true;
}
inline bool encryptedLine(const std::string& s, std::string* normalized) {
  if(s.size()!=15 || s[4]!='-' || s[9]!='-') return false;
  std::string t=upper(s);
  for(size_t i=0;i<t.size();++i) if(i!=4 && i!=9 && std::string("0123456789ABCDEFGHJKMNPQRTUVWXYZ").find(t[i])==std::string::npos) return false;
  *normalized=t; return true;
}
inline bool pnachLine(const std::string& s, std::string* normalized) {
  if(s.rfind("patch=",0)!=0 || s.back()==',') return false;
  std::vector<std::string> v; std::istringstream in(s.substr(6)); std::string t;
  while(std::getline(in,t,',')) v.push_back(trim(t));
  if(v.size()!=5 || (v[0]!="0" && v[0]!="1" && v[0]!="2" && v[0]!="3") || (v[1]!="EE" && v[1]!="IOP") || !hex(v[2],8,8)) return false;
  const size_t width=v[3]=="byte"?2:v[3]=="short"?4:v[3]=="word"?8:v[3]=="double"?16:v[3]=="extended"?8:0;
  if(!width || !hex(v[4],1,width)) return false;
  *normalized="patch="+v[0]+","+v[1]+","+upper(v[2])+","+v[3]+","+upper(v[4]); return true;
}
inline Result parse(const std::string& input, const std::string& type, const std::string& name, const std::string& creator={}) {
  Result r;
  if(input.empty() || input.size()>262144 || input.find('\0')!=std::string::npos) {r.error="size";return r;}
  if(type!="gecko" && type!="actionReplay" && type!="pnach" && type!="ini") {r.error="format";return r;}
  if(!safeName(name) || (!creator.empty() && !safeName(creator))) {r.error="name";return r;}
  Entry entry{name,creator,type,{}, {},false};
  bool selected=type!="ini", hasMode=false; size_t total=0;
  auto flush=[&](){if(!entry.lines.empty()) {r.entries.push_back(entry);entry.lines.clear();entry.notes.clear();hasMode=false;}};
  std::istringstream in(input); std::string line; size_t number=0;
  while(std::getline(in,line)) {
    ++number; line=trim(line); if(number==1 && line.rfind("\xEF\xBB\xBF",0)==0) line.erase(0,3);
    if(line.empty()) continue;
    if(line.empty() || line[0]=='#' || line[0]==';' || line.rfind("//",0)==0) continue;
    if(line.front()=='[') {
      if(line.back()!=']') {r.error="format";break;}
      if(type=="ini") {flush(); std::string section=line.substr(1,line.size()-2);selected=section=="Gecko" || section=="ActionReplay";entry=Entry{};entry.type=section=="Gecko"?"gecko":"actionReplay";continue;}
      if(type=="pnach") {flush();entry=Entry{};entry.type="pnach";entry.name=line.substr(1,line.size()-2);entry.creator=creator;if(!safeName(entry.name)){r.error="name";break;}continue;}
      r.error="format";break;
    }
    if(!selected) continue; // Never import enabled lists or unrelated game settings.
    if(type=="ini" && (line.front()=='$' || line.rfind("+$",0)==0)) {
      flush(); entry.lines.clear(); entry.notes.clear(); entry.encrypted=false;hasMode=false;
      std::string title=line.substr(line.front()=='+'?2:1);const auto bracket=title.find('[');
      entry.creator.clear();
      if(bracket!=std::string::npos) {if(title.back()!=']'){r.error="name";break;}entry.creator=trim(title.substr(bracket+1,title.size()-bracket-2));title.resize(bracket);}
      entry.name=trim(title);
      if(!safeName(entry.name) || (!entry.creator.empty() && !safeName(entry.creator))) {r.error="name";break;}
      continue;
    }
    if(type=="pnach" && (line.rfind("gametitle=",0)==0 || line.rfind("comment=",0)==0 || line.rfind("description=",0)==0 || line.rfind("author=",0)==0)) {
      if(line.rfind("author=",0)==0) entry.creator=trim(line.substr(7)); else entry.notes.push_back(line);continue;
    }
    if(line[0]=='*' && entry.type=="gecko") {entry.notes.push_back(line.substr(1));continue;}
    if(entry.name.empty()) {r.error="name";break;}
    const auto comment=line.find("//");
    if(comment!=std::string::npos) line=trim(line.substr(0,comment));
    std::string normalized; bool encrypted=false;
    bool ok=entry.type=="pnach"?pnachLine(line,&normalized):rawLine(line,&normalized);
    if(!ok && entry.type=="actionReplay") ok=encrypted=encryptedLine(line,&normalized);
    if(!ok || (hasMode && encrypted!=entry.encrypted)) {r.error="code";break;}
    hasMode=true;entry.encrypted=encrypted;entry.lines.push_back(normalized);
    if(++total>8192 || r.entries.size()>512) {r.error="size";break;}
  }
  if(!r.error.empty()) {r.line=number;r.entries.clear();return r;}
  flush(); if(r.entries.empty()) r.error="empty";
  return r;
}
// WiiRD/Ocarina text: verify the returned GameID and never accept an HTML error page.
inline Result geckoDownload(const std::string& input,const std::string& id) {
  Result out; if(input.size()>1048576) {out.error="size";return out;}
  std::istringstream in(input);std::string line;
  if(!std::getline(in,line) || upper(trim(line))!=upper(id)) {out.error="identity";return out;}
  std::getline(in,line); // title
  Entry entry;entry.type="gecko";bool invalid=false,notes=false;
  auto flush=[&](){if(!entry.lines.empty() && !invalid)out.entries.push_back(entry);entry=Entry{};entry.type="gecko";invalid=false;notes=false;};
  while(std::getline(in,line)) {
    line=trim(line); if(line.empty()){flush();continue;}
    if(entry.name.empty()) {const auto p=line.find('[');entry.name=trim(line.substr(0,p));if(p!=std::string::npos && line.back()==']')entry.creator=line.substr(p+1,line.size()-p-2);continue;}
    std::string normalized;
    if(!notes && rawLine(line,&normalized)) entry.lines.push_back(normalized);
    else {if(!notes && line.size()==17 && line[8]==' ')invalid=true;notes=true;entry.notes.push_back(line);}
  }
  flush(); return out;
}
} // namespace NeoCheat
