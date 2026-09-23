#!/usr/bin/env python3
"""Compile actual Dolphin loaders and NeoStation save/resolve functions.

The INI filesystem is an in-memory double with upstream append-on-merge
semantics. Code parsing, enabling/disabling, serialization, filename order and
the adapter functions are taken verbatim from the pinned production sources.
"""
from pathlib import Path
import argparse
import importlib.util
import shutil
import subprocess
import tempfile
from rpcs3_atomic_startup_test import extract_function

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--upstream', type=Path, required=True)
upstream = parser.parse_args().upstream.resolve()
pin = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
assert pin == '7cac54161659421ed95c2cd1c0b0746539a4cd38', pin
spec = importlib.util.spec_from_file_location('dolphin_patch', ROOT / 'build-utils/patch_dolphin_internal_core_v2.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
bridge = module.BRIDGE_SOURCE
gecko = (upstream / 'Source/Core/Core/GeckoCodeConfig.cpp').read_text()
config = (upstream / 'Source/Core/Core/ConfigLoaders/GameConfigLoader.cpp').read_text()
enabled = (upstream / 'Source/Core/Core/CheatCodes.h').read_text()

program = r'''
#include <algorithm>
#include <cassert>
#include <cstdint>
#include <iostream>
#include <map>
#include <optional>
#include <sstream>
#include <string>
#include <vector>
using u16=uint16_t; using u32=uint32_t;
namespace Common {
struct IniFile {
  using Sections=std::map<std::string,std::vector<std::string>>;
  Sections sections;
  static inline std::map<std::string,Sections> files;
  bool Load(const std::string& path,bool merge=false) {
    if(!merge) sections.clear();
    if(!files.count(path)) return false;
    for(const auto& [name,lines]:files[path])
      sections[name].insert(sections[name].end(),lines.begin(),lines.end());
    return true;
  }
  bool Save(const std::string& path) { files[path]=sections; return true; }
  bool GetLines(const std::string& name,std::vector<std::string>* lines,bool=false) const {
    const auto it=sections.find(name); *lines=it==sections.end()?std::vector<std::string>{}:it->second; return it!=sections.end();
  }
  void SetLines(const std::string& name,const std::vector<std::string>& lines) { sections[name]=lines; }
};
}
std::string StripWhitespace(std::string s) {
  const auto begin=s.find_first_not_of(" \t\r\n"),end=s.find_last_not_of(" \t\r\n");
  return begin==std::string::npos?"":s.substr(begin,end-begin+1);
}
namespace fmt { std::string format(const char*,u16 n) { return "r"+std::to_string(n); } }
constexpr int D_GAMESETTINGS_IDX=1;
namespace File { std::string GetUserPath(int) { return "user/"; } }
namespace ConfigLoaders {
// FILE_NAMES
}
struct SConfig {
  static Common::IniFile LoadLocalGameIni(const std::string&,std::optional<u16>);
  static Common::IniFile LoadDefaultGameIni(const std::string&,u16) { return {}; }
};
// LOCAL_LOADER
// ENABLED_READERS
namespace Gecko {
struct GeckoCode {
  struct Code { u32 address=0,data=0; std::string original_line; };
  std::string name,creator; std::vector<std::string> notes; std::vector<Code> codes;
  bool enabled=false,default_enabled=false,user_defined=false;
};
std::optional<GeckoCode::Code> DeserializeLine(const std::string& line) {
  GeckoCode::Code code; code.original_line=line;
  std::istringstream in(line); if(in>>std::hex>>code.address>>code.data) return code;
  return {};
}
// GECKO_FUNCTIONS
}
namespace ActionReplay { struct ARCode {};
std::vector<ARCode> LoadCodes(const Common::IniFile&,const Common::IniFile&) { return {}; } }
std::string g_game_id="GZLE01"; u16 g_game_revision=1;
void DOLRefreshRuntimeGameIdentity() {}
// ADAPTER_FUNCTIONS
int main() {
  auto& fs=Common::IniFile::files;
  fs["user/GZL.ini"]={{"Gecko",{"$Family [Author]","04000000 00000001"}},
                        {"Gecko_Disabled",{"$Family"}}};
  fs["user/GZLE01.ini"]={{"Gecko",{"$Region","04000004 00000002"}},
                           {"Gecko_Enabled",{"$Region"}}};
  fs["user/GZLE01r1.ini"]={{"Gecko",{"$Revision","04000008 00000003"}},
                             {"Gecko_Enabled",{"$Family"}},
                             {"Gecko_Disabled",{"$Region"}},
                             {"Other",{"keep-me"}}};
  const auto familyFile=fs["user/GZL.ini"], regionFile=fs["user/GZLE01.ini"];
  std::vector<Gecko::GeckoCode> codes;
  DOLLoadCheatLists(&codes,nullptr);
  assert(codes.size()==3 && codes[0].enabled && !codes[1].enabled);
  assert(codes[0].codes[0].address==0x04000000);
  codes[0].enabled=false; codes[1].enabled=true;
  assert(DOLSaveGeckoCodes(codes));
  codes.clear(); DOLLoadCheatLists(&codes,nullptr);
  assert(codes.size()==3 && !codes[0].enabled && codes[1].enabled);
  assert(fs["user/GZL.ini"]==familyFile && fs["user/GZLE01.ini"]==regionFile);
  assert(fs["user/GZLE01r1.ini"]["Other"]==std::vector<std::string>{"keep-me"});
  assert(fs["user/GZLE01r1.ini"]["Gecko"].size()==2); // only its owned definition
  // A downloaded definition is new, so persist it exactly once.
  Gecko::GeckoCode downloaded; downloaded.name="Downloaded"; downloaded.user_defined=true;
  downloaded.codes.push_back({0x04000010,4,"04000010 00000004"});
  codes.push_back(downloaded); assert(DOLSaveGeckoCodes(codes));
  DOLLoadCheatLists(&codes,nullptr); assert(codes.size()==4);
  assert(DOLSaveGeckoCodes(codes)); DOLLoadCheatLists(&codes,nullptr); assert(codes.size()==4);
  // Another revision keeps its imported state; no guessed region is consulted.
  g_game_revision=2; DOLLoadCheatLists(&codes,nullptr);
  assert(codes.size()==2 && !codes[0].enabled && codes[1].enabled);
  g_game_id="GZLP01"; DOLLoadCheatLists(&codes,nullptr); assert(codes.size()==1);
  g_game_id="ABCD01"; DOLLoadCheatLists(&codes,nullptr); assert(codes.empty());
  // Wii uses the same hierarchical loader, but with Wii-specific system,
  // family and exact IDs. Keep this separate from the GameCube fixture so a
  // future GameCube-only regression cannot satisfy the contract.
  fs.clear(); g_game_id="RMGE01"; g_game_revision=2;
  fs["user/R.ini"]={{"Gecko",{"$Wii System","04000020 00000005"}}};
  fs["user/RMG.ini"]={{"Gecko",{"$Wii Family","04000024 00000006"}}};
  fs["user/RMGE01.ini"]={{"Gecko",{"$Wii Region","04000028 00000007"}},
                           {"Gecko_Enabled",{"$Wii Region"}}};
  fs["user/RMGE01r2.ini"]={{"Gecko",{"$Wii Revision","0400002c 00000008"}},
                             {"Gecko_Enabled",{"$Wii Family"}}};
  DOLLoadCheatLists(&codes,nullptr);
  assert(codes.size()==4 && codes[1].enabled && codes[2].enabled);
  std::cout<<"PASS: GameCube and Wii family/region/revision detection, on/off persistence, no duplicated definitions, imported files preserved, exact identity\n";
}
'''
program = program.replace('// FILE_NAMES', extract_function(config, 'std::vector<std::string> GetGameIniFilenames('))
program = program.replace('// LOCAL_LOADER', module.LOCAL_CHEAT_INI_SOURCE)
program = program.replace('// ENABLED_READERS',
    'template<typename T>\n' + extract_function(enabled, 'void ReadEnabledOrDisabled(') + '\n' +
    'template<typename T>\n' + extract_function(enabled, 'void ReadEnabledAndDisabled('))
program = program.replace('// GECKO_FUNCTIONS', '\n'.join(extract_function(gecko, name) for name in (
    'std::vector<GeckoCode> LoadCodes(', 'static std::string MakeGeckoCodeTitle(',
    'static void SaveGeckoCode(', 'void SaveCodes(')))
adapter = extract_function(bridge, 'static void DOLLoadCheatLists(')
adapter += '\ntemplate<typename Code>\n' + extract_function(bridge, 'static void DOLPrepareCodesForSave(')
adapter += '\n' + extract_function(bridge, 'static std::string DOLCheatOverridePath(')
adapter += '\n' + extract_function(bridge, 'static bool DOLSaveGeckoCodes(')
program = program.replace('// ADAPTER_FUNCTIONS', adapter)
with tempfile.TemporaryDirectory(prefix='dolphin-cheat-catalog-') as directory:
    source = Path(directory) / 'test.cpp'
    binary = Path(directory) / 'test'
    source.write_text(program)
    subprocess.run([shutil.which('clang++') or 'g++', '-std=c++20', str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
