// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <array>
#include <algorithm>
#include <cstdint>
#include <cctype>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <set>
#include <string>
#include <vector>
#include <zlib.h>

namespace DOLTextures {
constexpr uint64_t maxPack = 2ULL*1024*1024*1024, maxFile = 128ULL*1024*1024;
struct File { std::string name, relative; uint32_t crc, compressed, size, offset, boundary; uint16_t method, flags; };
inline uint16_t u16(const unsigned char* p) { return p[0]|(uint16_t(p[1])<<8); }
inline uint32_t u32(const unsigned char* p) { return u16(p)|(uint32_t(u16(p+2))<<16); }
inline bool read(std::ifstream& in,uint64_t at,void* bytes,size_t count) {
  in.clear();in.seekg(at);in.read(static_cast<char*>(bytes),count);return bool(in);
}
struct Match { std::string relative, source; bool otherRegion = false; };
struct Scan { std::set<std::string> sources, otherRegions; bool valid = false; };
inline bool gameId(const std::string& value) {
  return value.size()==6 && std::all_of(value.begin(),value.end(),[](unsigned char c){return (c>='A' && c<='Z') || (c>='0' && c<='9');});
}
// Dolphin also accepts a three-character region-free folder. A six-character
// folder for another region is only a candidate: identical hashes are not
// guaranteed, so the UI must ask before importing it for the current game.
inline Match match(const std::string& name,const std::string& game) {
  if(!gameId(game))return {};
  if(name.empty() || name.front()=='/' || name.find('\\')!=std::string::npos || name.find(':')!=std::string::npos || name.find('\0')!=std::string::npos)return {};
  std::vector<std::string> parts;size_t start=0;
  while(start<name.size()) {auto end=name.find('/',start);auto part=name.substr(start,end-start);
    if(part.empty() || part=="." || part=="..")return {};
    parts.push_back(part);if(end==std::string::npos)break;start=end+1;
  }
  size_t root=parts.size();
  for(size_t i=0;i<parts.size();++i) {
    const bool family=parts[i]==game.substr(0,3);
    const bool regional=gameId(parts[i]) && parts[i].substr(0,3)==game.substr(0,3);
    if(family || regional){if(root!=parts.size())return {};root=i;}
  }
  if(root+1>=parts.size())return {};
  const auto& file=parts.back();
  if(file.rfind("tex1_",0)!=0 || !(file.ends_with(".png") || file.ends_with(".dds")))return {};
  std::string result;
  for(size_t i=root+1;i<parts.size();++i){if(!result.empty())result+='/';result+=parts[i];}
  return {result,parts[root],parts[root].size()==6 && parts[root]!=game};
}
inline std::string relative(const std::string& name,const std::string& game) {
  const auto result=match(name,game);return result.otherRegion?std::string{}:result.relative;
}
inline bool list(std::ifstream& in,const std::string& game,std::vector<File>& files,uint64_t& total,Scan* scan=nullptr,bool allowOtherRegion=false) {
  if(scan)*scan={};files.clear();total=0;
  in.seekg(0,std::ios::end);auto length=in.tellg();if(length<22 || uint64_t(length)>maxPack)return false;
  size_t tailSize=static_cast<size_t>(std::min<uint64_t>(uint64_t(length),65557));
  std::vector<unsigned char> tail(tailSize);if(!read(in,uint64_t(length)-tailSize,tail.data(),tailSize))return false;
  size_t eocd=tail.size();
  for(size_t i=tail.size()-22;;--i){if(u32(tail.data()+i)==0x06054b50 && i+22+u16(tail.data()+i+20)==tail.size()){eocd=i;break;}if(i==0)break;}
  if(eocd==tail.size())return false;
  const auto* e=tail.data()+eocd;uint32_t count=u16(e+10),dirSize=u32(e+12),at=u32(e+16);
  if(u16(e+4) || u16(e+6) || u16(e+8)!=count || count==65535 || count>20000 || uint64_t(at)+dirSize!=uint64_t(length)-tailSize+eocd)return false;
  const uint64_t dirEnd=uint64_t(at)+dirSize;std::set<std::string> destinations;total=0;files.clear();
  for(uint32_t i=0;i<count;++i) {
    std::array<unsigned char,46> h{};if(uint64_t(at)+46>dirEnd || !read(in,at,h.data(),h.size()) || u32(h.data())!=0x02014b50)return false;
    uint16_t nameSize=u16(h.data()+28),extra=u16(h.data()+30),comment=u16(h.data()+32);
    if(!nameSize || nameSize>1024 || uint64_t(at)+46+nameSize+extra+comment>dirEnd)return false;
    std::string name(nameSize,'\0');if(!read(in,at+46,name.data(),nameSize))return false;
    at+=46+nameSize+extra+comment;
    // Reject link entries, encrypted entries, split archives and ZIP64. Only
    // regular texture data is ever materialized, never metadata or executables.
    uint32_t mode=u32(h.data()+38)>>16;
    if((mode&0170000)==0120000 || u16(h.data()+34) || (u16(h.data()+8)&1))return false;
    const auto selection=match(name,game);if(selection.relative.empty())continue;
    if(selection.otherRegion && !allowOtherRegion){if(scan)scan->otherRegions.insert(selection.source);continue;}
    const auto& dest=selection.relative;
    File f{name,dest,u32(h.data()+16),u32(h.data()+20),u32(h.data()+24),u32(h.data()+42),u32(e+16),u16(h.data()+10),u16(h.data()+8)};
    std::string folded=dest;for(char& c:folded)c=static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    if((f.method!=0 && f.method!=8) || !f.size || f.size>maxFile || !f.compressed || f.compressed==0xffffffff || f.offset==0xffffffff || uint64_t(f.offset)+30+f.compressed>u32(e+16) || !destinations.insert(folded).second)return false;
    total+=f.size;if(total>maxPack)return false;files.push_back(std::move(f));if(scan)scan->sources.insert(selection.source);
  }
  if(scan)scan->valid=at==dirEnd;
  return at==dirEnd && !files.empty();
}
inline bool extract(std::ifstream& in,const File& file,const std::filesystem::path& output) {
  std::array<unsigned char,30> h{};if(!read(in,file.offset,h.data(),h.size()) || u32(h.data())!=0x04034b50 || u16(h.data()+6)!=file.flags || u16(h.data()+8)!=file.method)return false;
  uint16_t nameSize=u16(h.data()+26);std::string name(nameSize,'\0');
  if(name!=file.name && (!read(in,uint64_t(file.offset)+30,name.data(),nameSize) || name!=file.name))return false;
  uint64_t at=uint64_t(file.offset)+30+nameSize+u16(h.data()+28);
  if(at+file.compressed>file.boundary)return false;
  std::error_code error;std::filesystem::create_directories(output.parent_path(),error);if(error)return false;
  std::ofstream out(output,std::ios::binary|std::ios::trunc);if(!out)return false;
  std::array<unsigned char,65536> input{},decoded{};uint64_t produced=0;uint32_t remaining=file.compressed;uLong crc=crc32(0,nullptr,0);
  z_stream stream{};bool compressed=file.method==8,ok=true,ended=false;
  if(compressed && inflateInit2(&stream,-MAX_WBITS)!=Z_OK)return false;
  while(remaining && ok) {
    size_t n=std::min<size_t>(remaining,input.size());if(!read(in,at,input.data(),n)){ok=false;break;}at+=n;remaining-=n;
    if(!compressed){produced+=n;if(produced>file.size){ok=false;break;}out.write(reinterpret_cast<char*>(input.data()),n);crc=crc32(crc,input.data(),n);}
    else {
      stream.next_in=input.data();stream.avail_in=static_cast<uInt>(n);
      do {
        stream.next_out=decoded.data();stream.avail_out=decoded.size();int status=inflate(&stream,Z_NO_FLUSH);
        size_t written=decoded.size()-stream.avail_out;produced+=written;
        if(produced>file.size || (status!=Z_OK && status!=Z_STREAM_END)){ok=false;break;}
        out.write(reinterpret_cast<char*>(decoded.data()),written);crc=crc32(crc,decoded.data(),written);
        if(status==Z_STREAM_END){ended=true;if(stream.avail_in || remaining)ok=false;break;}
        if(!written && !stream.avail_in)break;
      }while(stream.avail_in || stream.avail_out==0);
    }
    if(!out)ok=false;
  }
  if(compressed)inflateEnd(&stream);out.close();
  ok=ok && !out.fail() && produced==file.size && crc==file.crc && (!compressed || ended);
  if(!ok)std::filesystem::remove(output,error);return ok;
}
}
