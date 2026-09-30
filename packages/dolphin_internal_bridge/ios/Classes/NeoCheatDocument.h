// SPDX-License-Identifier: GPL-3.0-or-later
// File-only parser: names delimit cheats, NEVER blank lines inside a code block.
#pragma once
#include "NeoCheatParser.h"
namespace NeoCheat {
inline bool documentEncryptedShape(const std::string& text) {
  const auto s=trim(text);
  if(s.size()>=10 && s[4]=='-' && s[9]=='-')return true;
  std::istringstream stream(s);std::string a,b,c,extra;
  if(stream>>a>>b>>c && !(stream>>extra) && a.size()==4 && b.size()==4 && c.size()==5)return true;
  return s.size()==13 && s.find_first_of(" \t")==std::string::npos &&
      std::any_of(s.begin(),s.end(),[](unsigned char ch){return std::isdigit(ch)!=0;});
}
inline bool documentCodeShaped(const std::string& s) {
  std::istringstream stream(s);std::string a,b;stream>>a>>b;
  // Word length alone is not a code signature: "Infinite Grenades" has
  // two eight-letter words. Keep rejecting damaged hexadecimal pairs,
  // including placeholder X/? bytes, without rejecting ordinary titles.
  const auto damagedHex=[](const std::string& word) {
    return word.size()==8 && std::all_of(word.begin(),word.end(),[](unsigned char ch) {
      return std::isxdigit(ch)!=0 || ch=='X' || ch=='x' || ch=='?';
    });
  };
  return s.rfind("patch",0)==0 || s.find('=')!=std::string::npos ||
      (damagedHex(a) && damagedHex(b)) || hex(a,7,16) ||
      a.rfind("0x",0)==0 || documentEncryptedShape(s);
}
inline bool documentTitle(std::string text,Entry* entry,bool brackets=false) {
  if(text.rfind("+$",0)==0)text.erase(0,2);
  else if(text.rfind("$",0)==0)text.erase(0,1);
  if(brackets)text=text.substr(1,text.size()-2);
  entry->creator.clear();
  const auto author=text.find('[');
  if(author!=std::string::npos) {
    if(text.back()!=']')return false;
    entry->creator=trim(text.substr(author+1,text.size()-author-2));text.resize(author);
  }
  entry->name=trim(text);
  return safeName(entry->name) && (entry->creator.empty() || safeName(entry->creator));
}
inline Result parseDocument(const std::string& input,const std::string& requested,
                            const std::string& fallbackName,const std::string& creator={},
                            const std::string& expectedGameId={}) {
  Result result;
  auto fail=[&](const std::string& key,size_t line){result.error=key;result.line=line;result.entries.clear();return result;};
  if(input.empty())return fail("empty",0);
  if(input.size()>262144 || input.find('\0')!=std::string::npos)return fail("size",0);
  if(requested!="gecko" && requested!="actionReplay" && requested!="ini" && requested!="pnach")return fail("format",0);
  const bool ps2=requested=="pnach";
  std::vector<std::string> lines;std::istringstream in(normalizeText(input));std::string text;
  while(std::getline(in,text))lines.push_back(trim(text));
  bool ini=false;
  for(const auto& line:lines)if(line=="[Gecko]" || line.rfind("[Gecko] ",0)==0 ||
      line.rfind("[ActionReplay]",0)==0 || line.rfind("[Action Replay]",0)==0)ini=true;
  if(ps2 && ini)return fail("format",1);
  ini=ini || (!ps2 && requested=="ini");
  // PNACH 2.0 groups are authoritative. Comments inside a named group,
  // even after blank lines, must never rename or split that group. The
  // comment-heading convention is retained only for legacy ungrouped files.
  const bool pnachGroups=ps2 && std::any_of(lines.begin(),lines.end(),[](const auto& line) {
    return line.size()>=2 && line.front()=='[' && line.back()==']';
  });
  size_t start=0;while(start<lines.size() && lines[start].empty())++start;
  std::string nextValue;
  const bool nextIsCode=start+1<lines.size() && (rawLine(lines[start+1],&nextValue) ||
      (documentEncryptedShape(lines[start+1]) && encryptedLine(lines[start+1],&nextValue)));
  if(!ps2 && start<lines.size() && lines[start].size()==6 && validId(lines[start]) && !nextIsCode) {
    if(expectedGameId.empty() || upper(lines[start])!=upper(expectedGameId))return fail("identity",start+1);
    ++start; // WiiRD/Ocarina: GameID, game title, then named cheats.
    if(start>=lines.size())return fail("empty",start+1);
    ++start;
    ini=false;
  }
  std::string baseType=ps2?"pnach":requested=="actionReplay"?"actionReplay":"gecko";
  std::string sectionType=baseType;
  Entry entry{fallbackName.empty()?"Imported cheat":fallbackName,creator,baseType,{},{},false};
  bool selected=!ini,named=false,hasMode=false,boundary=true;
  size_t total=0,titleLine=0;
  auto flush=[&]() {
    if(named && entry.lines.empty()){result.error="emptyBlock";result.line=titleLine;return false;}
    if(!entry.lines.empty()) {
      if(result.entries.size()>=512){result.error="size";return false;}
      result.entries.push_back(entry);
    }
    entry=Entry{fallbackName.empty()?"Imported cheat":fallbackName,creator,sectionType,{},{},false};
    named=false;hasMode=false;return true;
  };
  auto dataLine=[&](std::string line,std::string* value,bool* encrypted) {
    const auto comment=line.find("//");if(comment!=std::string::npos)line=trim(line.substr(0,comment));
    *encrypted=false;
    if(ps2)return pnachLine(line,value);
    if(rawLine(line,value))return true;
    if((!ini || sectionType=="actionReplay") && documentEncryptedShape(line) && encryptedLine(line,value)) {
      *encrypted=true;return true;
    }
    return false;
  };
  auto followedByCode=[&](size_t index) {
    for(size_t j=index+1;j<lines.size();++j) {
      const auto& next=lines[j];
      if(next.empty() || next.rfind("*",0)==0 || next.rfind("//",0)==0 || next.rfind("#",0)==0 || next.rfind(";",0)==0)continue;
      std::string value;bool encrypted=false;return dataLine(next,&value,&encrypted);
    }
    return false;
  };
  for(size_t i=start;i<lines.size();++i) {
    const std::string& line=lines[i];
    if(line.empty()){boundary=true;continue;}
    if(line.front()=='[' && ini) {
      if(!flush())return fail(result.error,result.line?result.line:i+1);
      const auto close=line.find(']');if(close==std::string::npos)return fail("format",i+1);
      const auto section=line.substr(1,close-1);
      selected=section=="Gecko" || section=="ActionReplay" || section=="Action Replay";
      sectionType=section=="Gecko"?"gecko":"actionReplay";
      entry.type=sectionType;boundary=true;continue;
    }
    if(!selected)continue; // Enabled/Disabled lists and graphics settings are not cheats.
    const bool comment=line.rfind("//",0)==0 || line.front()=='#' || line.front()==';';
    if(comment) {
      // Conventional PNACH headings separated from the previous block. A comment
      // between consecutive patch lines stays a comment, not a second cheat.
      std::string title=trim(line.substr(line.rfind("//",0)==0?2:1));
      if(ps2 && !pnachGroups && boundary && !ini && followedByCode(i) && safeName(title) &&
          title.find('=')==std::string::npos && title.find("http")==std::string::npos) {
        if(!flush())return fail(result.error,result.line?result.line:i+1);
        if(!documentTitle(title,&entry))return fail("name",i+1);
        entry.type=baseType;named=true;titleLine=i+1;boundary=false;
      }
      continue;
    }
    if(line.front()=='*') {if(!entry.lines.empty() || named)entry.notes.push_back(line.substr(1));continue;}
    if(ps2 && (line.rfind("gametitle=",0)==0 || line.rfind("comment=",0)==0 ||
        line.rfind("description=",0)==0 || line.rfind("author=",0)==0)) {
      if(line.rfind("author=",0)==0){entry.creator=trim(line.substr(7));if(!entry.creator.empty() && !safeName(entry.creator))return fail("name",i+1);}
      else entry.notes.push_back(line);
      continue;
    }
    const bool bracketTitle=line.front()=='[' && line.back()==']';
    if(line.front()=='$' || line.rfind("+$",0)==0 || bracketTitle) {
      if(!flush())return fail(result.error,result.line?result.line:i+1);
      if(!documentTitle(line,&entry,bracketTitle))return fail("name",i+1);
      entry.type=ini?sectionType:baseType;named=true;titleLine=i+1;boundary=false;continue;
    }
    std::string value;bool encrypted=false;
    if(dataLine(line,&value,&encrypted)) {
      if(ini && !named)return fail("name",i+1);
      if(!safeName(entry.name) || (!entry.creator.empty() && !safeName(entry.creator)))return fail("name",i+1);
      if(hasMode && entry.encrypted!=encrypted)return fail("mixedFormat",i+1);
      if(encrypted && !ini)entry.type="actionReplay";
      hasMode=true;entry.encrypted=encrypted;entry.lines.push_back(value);boundary=false;
      if(++total>8192 || (encrypted && entry.lines.size()>127))return fail("size",i+1);
      continue;
    }
    if(documentCodeShaped(line) || line.find('<')!=std::string::npos || line.find('>')!=std::string::npos)return fail("code",i+1);
    // Unmarked TXT title: a human-readable line immediately preceding a code.
    // Blank lines alone never end a code (AR verification + body stay together).
    if(!ini && ((!named && entry.lines.empty()) || followedByCode(i))) {
      if(!flush())return fail(result.error,result.line?result.line:i+1);
      if(!documentTitle(line,&entry))return fail("name",i+1);
      entry.type=baseType;named=true;titleLine=i+1;boundary=false;continue;
    }
    if(!ini && !entry.lines.empty()){entry.notes.push_back(line);continue;}
    return fail("code",i+1);
  }
  if(!flush())return fail(result.error,result.line?result.line:lines.size());
  if(result.entries.empty())return fail("empty",lines.size());
  return result;
}
} // namespace NeoCheat
