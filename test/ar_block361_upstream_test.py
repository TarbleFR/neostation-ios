"""Run the exact upstream Dolphin AR decryptor, not a format-only mock."""
from pathlib import Path
import hashlib, subprocess, tempfile, urllib.request
ROOT=Path(__file__).resolve().parents[1]
url='https://raw.githubusercontent.com/OatmealDome/dolphin-ios/7cac54161659421ed95c2cd1c0b0746539a4cd38/Source/Core/Core/ARDecrypt.cpp'
data=urllib.request.urlopen(url,timeout=30).read()
assert hashlib.sha256(data).hexdigest()=='c1652ce1dd48c61a0f3a2f177595444be657b1d0ebb7c41abc2258742293f8d5'
with tempfile.TemporaryDirectory(prefix='neo-ar-exact-') as temporary:
    tmp=Path(temporary)
    files={
      'Core/ARDecrypt.h': '#pragma once\n#include <vector>\n#include <string>\n#include "Common/CommonTypes.h"\nnamespace ActionReplay { struct AREntry{ u32 cmd_addr,value;AREntry(u32 a,u32 b):cmd_addr(a),value(b){} }; void DecryptARCode(std::vector<std::string>,std::vector<AREntry>*); }\n',
      'Common/CommonTypes.h':'#pragma once\n#include <cstdint>\nusing u8=uint8_t;using u16=uint16_t;using u32=uint32_t;\n',
      'Common/Swap.h':'#pragma once\n#include "Common/CommonTypes.h"\nnamespace Common {inline u32 swap32(u32 x){return __builtin_bswap32(x);}}\n',
      'Common/StringUtil.h':'#pragma once\n#include <string>\n#include <cctype>\nnamespace Common { inline void ToUpper(std::string* s){for(char& c:*s)c=static_cast<char>(std::toupper(static_cast<unsigned char>(c)));}}\n',
      'Common/MsgHandler.h':'#pragma once\n#include <stdexcept>\ntemplate<class...Args> void PanicAlertFmtT(Args&&...){throw std::runtime_error("Upstream AR parity check failed");}\n',
    }
    for name,text in files.items():
        dest=tmp/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_text(text)
    (tmp/'ARDecrypt.cpp').write_bytes(data) # preserve original bytes/attributions
    (tmp/'main.cpp').write_text(r'''#include "NeoCheatParser.h"
#include "Core/ARDecrypt.h"
#include <fstream>
#include <iterator>
#include <iostream>
#include <cassert>
int main(int argc,char** argv){assert(argc==2);std::ifstream in(argv[1]);std::string data((std::istreambuf_iterator<char>(in)),{});
 auto parsed=NeoCheat::parse(data,"gecko","Auto Aim","Nikra");
 assert(parsed && parsed.entries.size()==1 && parsed.entries[0].lines.size()==5);
 std::vector<std::string> block;
 for(auto line:parsed.entries[0].lines){line.erase(std::remove(line.begin(),line.end(),'-'),line.end());block.push_back(line);}
 std::vector<ActionReplay::AREntry> ops;ActionReplay::DecryptARCode(block,&ops);
 assert(ops.size()==4); // five encrypted lines include one verification line.
 std::cout<<"PASS: full five-line user block decrypts as one Action Replay code with "<<ops.size()<<" operations in the exact pinned Dolphin decryptor\n";
}''')
    binary=tmp/'check'
    subprocess.run(['clang++','-std=c++20','-I'+str(tmp),'-I'+str(ROOT/'native/cheats'),str(tmp/'main.cpp'),str(tmp/'ARDecrypt.cpp'),'-o',str(binary)],check=True,timeout=40)
    subprocess.run([str(binary),str(ROOT/'test/fixtures/re4_user_ar_block.txt')],check=True,timeout=10)
