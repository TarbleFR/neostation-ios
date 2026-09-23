#!/usr/bin/env python3
"""Execute BIOS boot-parameter/path contracts and the production GS whitelist.

No JIT, GPU, BIOS ROM or device emulation is simulated as validated here. The
production parameter selection and path validation are compiled unchanged
against small type/filesystem stand-ins. --upstream verifies GS keys against
the exact pinned ARMSX2 source used by CI.
"""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream',type=Path)
    args=parser.parse_args()
    core=(ROOT/'packages/armsx2_internal_bridge/core/ARMSX2Core.mm').read_text()
    core=core.replace('#include "ARMSX2Patches.inc"', (ROOT/'packages/armsx2_internal_bridge/core/ARMSX2Patches.inc').read_text())
    headers=ROOT/'packages/armsx2_internal_bridge/ios/Classes'
    abi=(headers/'ARMSX2CoreABI.h').read_text()
    manifest=json.loads((ROOT/'build-utils/armsx2/source.json').read_text())
    assert manifest['abi_version']==int(re.search(r'NEO_ARMSX2_ABI_VERSION (\d+)u',abi)[1])==5
    assert 'get_available_patches_json' in abi and 'set_patch_state' in abi
    assert 'int get_available_patches_json(' in core and 'int set_patch_state(' in core
    start=core.index('      VMBootParameters parameters;')
    end=core.index('      if (vtlb_FastmemAreaUnavailable())',start)
    params=core[start:end]
    start=core.index('  const bool bios_only=',core.index('int boot('))
    end=core.index('  auto& r=runtime();',start)
    guard=core[start:end]
    table=(headers/'ARMSX2GraphicsHacks.h').read_text()
    keys=re.findall(r'^  \{"([^"]+)"',table,re.M)
    assert len(keys)==len(set(keys))==13
    if args.upstream:
        revision=subprocess.check_output(['git','-C',str(args.upstream),'rev-parse','HEAD'],text=True).strip()
        assert revision==manifest['revision']
        config=(args.upstream/'pcsx2/Pcsx2Config.cpp').read_text()
        for key in keys:
            assert re.search(r'SettingsWrapBitBoolEx\([^\n]*"'+re.escape(key)+r'"\)',config), key
        bridge=(args.upstream/'platforms/ios/app/src/main/cpp/ARMSX2Bridge.mm').read_text()
        assert 'ARMSX2SyncClaimsIfPinnedHackKey(si, section, key);' in bridge
        assert 'ARMSX2RequestPerGameSettingsReload();' in bridge
        print('Verified boolean GS keys and per-game persistence against pinned upstream',revision)
    else:
        print('Offline contracts only; upstream key check will run in native CI.')
    compiler=shutil.which('clang++') or shutil.which('g++')
    if not compiler: raise SystemExit('C++ compiler required')
    program=r'''
#include "ARMSX2CoreABI.h"
#include "ARMSX2GraphicsHacks.h"
#include <iostream>
#include <string>
#include <stdexcept>
#include <optional>
#include <cstring>
enum class CDVD_SourceType { NoDisc, Iso };
struct VMBootParameters {
  std::string filename,elf_override;
  std::optional<bool> fast_boot;
  bool disable_achievements_hardcore_mode=false;
  std::optional<CDVD_SourceType> source_type;
};
struct Runtime { uint32_t kind; std::string game; };
VMBootParameters parameters_for(const Runtime& r) {
'''+params+r'''
  return parameters;
}
namespace FileSystem { bool FileExists(const char* p) { return std::strcmp(p,"/game.iso")==0; } }
int error_out(const char*, char*, size_t) { return 0; }
int validate_boot(const char* path,uint32_t kind) {
  char* error=nullptr; size_t capacity=0;
'''+guard+r'''
  return 1;
}
void require(bool value,const char* message) { if(!value) throw std::runtime_error(message); }
int main() {
  const auto bios=parameters_for({NEO_ARMSX2_BOOT_BIOS,""});
  require(bios.source_type==CDVD_SourceType::NoDisc,"BIOS must not insert a disc");
  require(bios.fast_boot==false && bios.filename.empty() && bios.elf_override.empty(),"BIOS browser must not fast boot");
  const auto disc=parameters_for({NEO_ARMSX2_BOOT_DISC,"/game.iso"});
  require(disc.source_type==CDVD_SourceType::Iso && disc.filename=="/game.iso" && disc.fast_boot==true,"Disc fast boot changed");
  const auto elf=parameters_for({NEO_ARMSX2_BOOT_ELF,"/game.iso"});
  require(elf.source_type==CDVD_SourceType::NoDisc && elf.elf_override=="/game.iso","ELF route changed");
  require(validate_boot("",NEO_ARMSX2_BOOT_BIOS),"BIOS empty path rejected");
  require(!validate_boot(nullptr,NEO_ARMSX2_BOOT_BIOS),"BIOS null path accepted");
  require(!validate_boot("/game.iso",NEO_ARMSX2_BOOT_BIOS),"BIOS with a disc accepted");
  require(validate_boot("/game.iso",NEO_ARMSX2_BOOT_DISC),"Disc rejected");
  require(validate_boot("/game.iso",NEO_ARMSX2_BOOT_ELF),"ELF rejected");
  require(!validate_boot("",NEO_ARMSX2_BOOT_DISC),"Empty ROM accepted");
  require(!validate_boot("/missing",NEO_ARMSX2_BOOT_DISC),"Missing ROM accepted");
  require(!validate_boot("/game.iso",99),"Unknown boot kind accepted");
  for(const auto& hack:kNeoARMSX2GraphicsHacks) {
    for(int value:{-1,0,1}) require(NeoARMSX2ValidGraphicsHack(hack.key,value),"Valid GS choice rejected");
    require(!NeoARMSX2ValidGraphicsHack(hack.key,-2) && !NeoARMSX2ValidGraphicsHack(hack.key,2),"Invalid GS choice accepted");
  }
  require(!NeoARMSX2ValidGraphicsHack("Renderer",1),"Renderer is not a hack");
  require(!NeoARMSX2ValidGraphicsHack("unknown",1),"Arbitrary setting accepted");
  std::cout<<"PASS: BIOS/disc/ELF parameters; path rejection; 13-key whitelist; inherit/on/off validation\n";
}
'''
    with tempfile.TemporaryDirectory(prefix='armsx2-bios-hacks-') as directory:
        source=Path(directory)/'test.cpp'; binary=Path(directory)/'test'
        source.write_text(program)
        subprocess.run([compiler,'-std=c++17','-Wall','-Wextra','-Werror','-I',str(headers),str(source),'-o',str(binary)],check=True)
        subprocess.run([str(binary)],check=True,timeout=10)
    # Source guards complement, not replace, the executable tests above.
    setter=core[core.index('int set_graphics_hack('):core.index('const NeoARMSX2API api=')]
    assert 'setGraphicsHackPinned:' not in setter, 'Must not alter global hack claims'
    assert 'setINIBool:' not in setter, 'Must not alter global settings'
    assert 'deletePerGameINIValue:' in setter and 'setPerGameINIBool:' in setter
    assert 'Host::RunOnCPUThread' in setter
    print('PASS: per-game-only writes on the owned CPU thread')

if __name__=='__main__': main()
