#!/usr/bin/env python3
"""Run the production ObjC++ patch adapter with Foundation and a controlled VM.

The fake VM deliberately separates disk settings from its loaded settings.
This reproduces the reported selection-without-activation defect. Run on macOS;
the native build executes this gate before compiling the iOS Core.
"""
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
if platform.system() != 'Darwin':
    raise SystemExit('Requires macOS Foundation; run the ARMSX2 native CI gate.')

SOURCE = r'''
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cassert>
#include <cstring>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <vector>
using u32 = unsigned;
static bool running=true, hardcore=false, savedMaster=false;
static int settingsReloads=0, fileReloads=0;
static std::map<std::string,std::vector<std::string>> disk, memory;
struct { bool EnableCheats=false; } EmuConfig;
bool has_running_game() { return running; }
int error_out(const std::string& text,char* error,size_t capacity) {
  if(capacity) { std::strncpy(error,text.c_str(),capacity-1); error[capacity-1]=0; }
  return 0;
}
namespace Host { template<class F> void RunOnCPUThread(F&& f,bool) { f(); } }
namespace Achievements { bool IsHardcoreModeActive() { return hardcore; } }
namespace VMManager {
std::string GetDiscSerial() { return "SLES-54182"; }
u32 GetDiscCRC() { return 0x301A1B6E; }
bool ReloadGameSettings() { settingsReloads++; memory=disk; EmuConfig.EnableCheats=savedMaster; return true; }
}
namespace Patch {
enum patch_place_type { PPT_ONCE_ON_LOAD, PPT_CONTINUOUSLY, PPT_COMBINED_0_1,
                       PPT_ON_LOAD_OR_WHEN_ENABLED, PPT_END_MARKER };
struct PatchInfo { std::string name,description,author; std::optional<patch_place_type> place; };
const char* PATCHES_CONFIG_SECTION="Patches";
const char* CHEATS_CONFIG_SECTION="Cheats";
const char* PATCH_ENABLE_CONFIG_KEY="Enable";
const char* PATCH_DISABLE_CONFIG_KEY="Disable";
std::vector<PatchInfo> GetPatchInfo(std::string_view serial,u32 crc,bool cheats,bool all,u32* count) {
  assert(serial=="SLES-54182" && crc==0x301A1B6E && !all);
  *count=cheats ? 0 : 3;
  if(cheats) return {{"Same name","Imported cheat","",PPT_CONTINUOUSLY}};
  return {{"Same name","Imported patch","",PPT_CONTINUOUSLY},
          {"Widescreen","","",PPT_ONCE_ON_LOAD}};
}
bool IsGloballyToggleablePatch(const PatchInfo& p) { return p.name=="Widescreen"; }
void ReloadPatches(const std::string&,u32,bool,bool,bool,bool) { fileReloads++; }
void UpdateActivePatches(bool,bool,bool,bool) {}
u32 GetActivePatchesCount() { return 3+memory["Patches/Enable"].size(); }
u32 GetActiveCheatsCount() { return EmuConfig.EnableCheats ? memory["Cheats/Enable"].size() : 0; }
}
@interface ARMSX2Bridge : NSObject
+ (NSArray*)patchEnableListForISO:(NSString*)iso section:(NSString*)section key:(NSString*)key;
+ (void)setPatchEnableList:(NSArray*)values forISO:(NSString*)iso section:(NSString*)section key:(NSString*)key;
+ (void)setPerGameINIBool:(NSString*)section key:(NSString*)key value:(BOOL)value forISO:(NSString*)iso;
@end
@implementation ARMSX2Bridge
+ (NSArray*)patchEnableListForISO:(NSString*)iso section:(NSString*)section key:(NSString*)key {
  NSMutableArray* result=[NSMutableArray array];
  for(const auto& name:disk[std::string(section.UTF8String)+"/"+key.UTF8String])
    [result addObject:[NSString stringWithUTF8String:name.c_str()]];
  return result;
}
+ (void)setPatchEnableList:(NSArray*)values forISO:(NSString*)iso section:(NSString*)section key:(NSString*)key {
  auto& list=disk[std::string(section.UTF8String)+"/"+key.UTF8String]; list.clear();
  for(NSString* value in values) list.emplace_back(value.UTF8String);
}
+ (void)setPerGameINIBool:(NSString*)section key:(NSString*)key value:(BOOL)value forISO:(NSString*)iso {
  assert([section isEqual:@"EmuCore"] && [key isEqual:@"EnableCheats"]); savedMaster=value;
}
@end
// PRODUCTION_ADAPTER
NSDictionary* snapshot() {
  char json[32768]={}; assert(get_available_patches_json(json,sizeof(json)));
  return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json length:strlen(json)] options:0 error:nil];
}
int main() { @autoreleasepool {
  NSDictionary* state=snapshot();
  assert([state[@"unlabelled"] intValue]==3);
  assert([state[@"activePatches"] intValue]==3);
  NSArray* items=state[@"items"]; assert(items.count==4);
  NSDictionary* patch=items[0]; NSDictionary* cheat=items[3];
  assert(![patch[@"cheat"] boolValue] && [cheat[@"cheat"] boolValue]);
  assert([items[2][@"readOnly"] boolValue]);
  char error[512]={};
  assert(set_patch_state([patch[@"id"] UTF8String],1,error,sizeof(error)));
  assert(settingsReloads==1 && fileReloads==1);
  assert(memory["Patches/Enable"]==std::vector<std::string>{"Same name"});
  assert(memory["Cheats/Enable"].empty());
  assert([snapshot()[@"activePatches"] intValue]==4);
  assert(set_patch_state([cheat[@"id"] UTF8String],1,error,sizeof(error)));
  assert(settingsReloads==2 && [snapshot()[@"activeCheats"] intValue]==1);
  assert(EmuConfig.EnableCheats);
  assert(set_patch_state([patch[@"id"] UTF8String],0,error,sizeof(error)));
  assert(memory["Patches/Enable"].empty() && !memory["Cheats/Enable"].empty());
  assert(set_patch_state([items[1][@"id"] UTF8String],0,error,sizeof(error)));
  assert(memory["Patches/Disable"]==std::vector<std::string>{"Widescreen"});
  assert(set_patch_state([items[1][@"id"] UTF8String],-1,error,sizeof(error)));
  assert(memory["Patches/Disable"].empty());
  const auto unchanged=disk;
  assert(!set_patch_state([cheat[@"id"] UTF8String],-1,error,sizeof(error)));
  assert(!set_patch_state("neo-patch-v1:broken",1,error,sizeof(error)));
  assert(!set_patch_state("missing",1,error,sizeof(error)));
  hardcore=true;
  assert(!set_patch_state([cheat[@"id"] UTF8String],1,error,sizeof(error)));
  assert(disk==unchanged);
  running=false;
  assert(!set_patch_state("Same name",1,error,sizeof(error)));
  running=true;
  char shortBuffer[2]={}; assert(!get_available_patches_json(shortBuffer,sizeof(shortBuffer)));
  puts("PASS: imported patches/cheats, unlabelled counts, typed selection, live settings reload, persistence and rejected states");
} }
'''
source = SOURCE.replace('// PRODUCTION_ADAPTER',
    (ROOT / 'packages/armsx2_internal_bridge/core/ARMSX2Patches.inc').read_text())
with tempfile.TemporaryDirectory(prefix='armsx2-patch-catalog-') as directory:
    path = Path(directory) / 'test.mm'
    binary = Path(directory) / 'test'
    path.write_text(source)
    subprocess.run(['clang++', '-std=c++20', '-fno-objc-arc', '-framework', 'Foundation',
                    str(path), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)
