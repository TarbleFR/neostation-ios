// SPDX-License-Identifier: GPL-3.0-or-later
#include "ARMSX2ShaderLibrary.h"

NSString* shader_bundle_root() {
  return [[NSString stringWithUTF8String:runtime().resources.c_str()] stringByAppendingPathComponent:@"shaders"];
}
NSString* shader_user_root() {
  return [[NSString stringWithUTF8String:runtime().data.c_str()] stringByAppendingPathComponent:@"shaders"];
}
NSString* shader_resolve(NSString* token) {
  return NeoShaderResolve(token,shader_bundle_root(),shader_user_root());
}

// The Swift app normally repairs these cached absolute paths. Its UI is not
// linked into NeoStation, so repair the existing INIs before the VM loads them.
// Only ARMSX2 shader keys change; saves, BIOS files and other cores are untouched.
void repair_shader_paths() {
  NSMutableArray* paths=[NSMutableArray arrayWithObject:
      [NSString stringWithUTF8String:Path::Combine(EmuFolders::Settings,"PCSX2.ini").c_str()]];
  NSString* games=[NSString stringWithUTF8String:EmuFolders::GameSettings.c_str()];
  for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:games error:nil])
    if ([name.pathExtension.lowercaseString isEqual:@"ini"])
      [paths addObject:[games stringByAppendingPathComponent:name]];
  for (NSString* path in paths) {
    INISettingsInterface si(path.UTF8String);
    if (!si.Load()) continue;
    const std::string token=si.GetStringValue("EmuCore/GS","ShaderChainPresetRef","");
    if (token.empty()) continue;
    NSString* resolved=shader_resolve([NSString stringWithUTF8String:token.c_str()]);
    if (resolved) si.SetStringValue("EmuCore/GS","ShaderChainPreset",resolved.UTF8String);
    else {
      si.SetBoolValue("EmuCore/GS","ShaderChainEnabled",false);
      si.DeleteValue("EmuCore/GS","ShaderChainPreset");
    }
    if (!si.Save()) throw std::runtime_error("Cannot repair ARMSX2 shader paths: " + std::string(path.UTF8String));
  }
}

int get_graphics_assets_json(char* output,size_t capacity) {
  if (!output || !capacity || !has_running_game()) return 0;
  @autoreleasepool {
    NSMutableArray* presets=[NSMutableArray arrayWithArray:NeoShaderScan(shader_bundle_root(),@"bundle")];
    [presets addObjectsFromArray:NeoShaderScan(shader_user_root(),@"data")];
    NSString* selected=[ARMSX2Bridge getPerGameINIString:@"EmuCore/GS" key:@"ShaderChainPresetRef" defaultValue:@"" forISO:nil];
    BOOL enabled=[ARMSX2Bridge getPerGameINIBool:@"EmuCore/GS" key:@"ShaderChainEnabled" defaultValue:NO forISO:nil];
    NSString* path=shader_resolve(selected);
    NSError* failure=path && enabled ? [ARMSX2Bridge shaderChainErrorForPreset:path] : nil;
    NSData* encoded=[NSJSONSerialization dataWithJSONObject:@{
      @"supported":@([ARMSX2Bridge isShaderChainSupported]), @"presets":presets,
      @"selected":enabled ? selected : @"", @"shaderError":failure.localizedDescription ?: @"",
      @"overlay":[NSNumber numberWithInt:[ARMSX2Bridge getPerGameINIInt:@"EmuCore/GS" key:@"NeoStationOsdPreset" defaultValue:0 forISO:nil]],
      @"packInstalled":@([NSFileManager.defaultManager fileExistsAtPath:
          [shader_user_root() stringByAppendingPathComponent:@"shaders_slang"]]),
    } options:0 error:nil];
    if (!encoded || encoded.length+1>capacity) return 0;
    memcpy(output,encoded.bytes,encoded.length); output[encoded.length]=0;
    return 1;
  }
}

int set_shader_preset(const char* raw,char* error,size_t capacity) {
  if (!raw || !has_running_game()) return error_out("Shader selection requires an active ARMSX2 game.",error,capacity);
  if (![ARMSX2Bridge isShaderChainSupported]) return error_out("This ARMSX2 core has no librashader runtime.",error,capacity);
  NSString* token=[NSString stringWithUTF8String:raw];
  if (!token) return error_out("Invalid shader identity.",error,capacity);
  NSString* path=token.length ? shader_resolve(token) : nil;
  if (token.length && !path) return error_out("The shader preset is missing or outside ARMSX2's shader directories.",error,capacity);
  BOOL success=NO;
  Host::RunOnCPUThread([&] {
    if (!VMManager::HasValidVM() || ![ARMSX2Bridge perGameIdentityKeyForCurrentGame].length) return;
    // One INI transaction and one reload, instead of live-reloading each key.
    const std::string ini=VMManager::GetGameSettingsPath(VMManager::GetDiscSerial(),VMManager::GetDiscCRC());
    INISettingsInterface si(ini);
    if (!si.Load() && FileSystem::FileExists(ini.c_str())) return;
    si.SetBoolValue("EmuCore/GS","ShaderChainEnabled",path!=nil);
    if (path) {
      si.SetStringValue("EmuCore/GS","ShaderChainPresetRef",token.UTF8String);
      si.SetStringValue("EmuCore/GS","ShaderChainPreset",path.UTF8String);
    } else {
      si.DeleteValue("EmuCore/GS","ShaderChainPresetRef");
      si.DeleteValue("EmuCore/GS","ShaderChainPreset");
    }
    success=si.Save();
    if (success) { VMManager::ReloadGameSettings(); [ARMSX2Bridge retryShaderChain]; }
  },true);
  return success ? 1 : error_out("Could not persist this game's shader selection.",error,capacity);
}

int set_performance_overlay(uint32_t preset,char* error,size_t capacity) {
  if (preset>3 || !has_running_game()) return error_out("Unsupported ARMSX2 performance overlay.",error,capacity);
  BOOL success=NO;
  Host::RunOnCPUThread([&] {
    if (!VMManager::HasValidVM() || ![ARMSX2Bridge perGameIdentityKeyForCurrentGame].length) return;
    const std::string ini=VMManager::GetGameSettingsPath(VMManager::GetDiscSerial(),VMManager::GetDiscCRC());
    INISettingsInterface si(ini);
    if (!si.Load() && FileSystem::FileExists(ini.c_str())) return;
    si.SetIntValue("EmuCore/GS","NeoStationOsdPreset",preset);
    si.SetIntValue("EmuCore/GS","OsdPerformancePos",preset ? 3 : 0);
    static const char* keys[]={"OsdShowFPS","OsdShowSpeed","OsdShowCPU","OsdShowVersion","OsdShowVPS","OsdShowGPU","OsdShowResolution","OsdShowIndicators","OsdShowGSStats","OsdShowFrameTimes","OsdShowHardwareInfo","OsdShowSettings","OsdShowInputs"};
    for (size_t i=0;i<std::size(keys);++i) si.SetBoolValue("EmuCore/GS",keys[i],preset>=(i<4 ? 1u : (i<8 ? 2u : 3u)));
    si.SetBoolValue("EmuCore/GS","OsdShowInputRec",false);
    success=si.Save();
    if (success) { VMManager::ReloadGameSettings(); }
  },true);
  return success ? 1 : error_out("Could not persist this game's performance overlay.",error,capacity);
}

int install_shader_pack(const char* archive,char* error,size_t capacity) {
  if (!archive || !has_running_game()) return error_out("Shader pack installation requires an active ARMSX2 session.",error,capacity);
  @autoreleasepool {
    NSFileManager* manager=NSFileManager.defaultManager;
    NSString* root=shader_user_root();
    NSString* destination=[root stringByAppendingPathComponent:@"shaders_slang"];
    // Don't overwrite files the renderer may still be using.
    if ([manager fileExistsAtPath:destination]) return 1;
    NSString* staged=[root stringByAppendingPathComponent:[@".install-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSError* failure=nil;
    NSArray* files=[ARMSX2Bridge extractShaderPackArchiveAtURL:
        [NSURL fileURLWithPath:[NSString stringWithUTF8String:archive]]
        toDirectory:[NSURL fileURLWithPath:staged] error:&failure];
    BOOL ok=files.count && !failure && NeoShaderScan(staged,@"data").count &&
        [manager moveItemAtPath:staged toPath:destination error:&failure];
    if (!ok) [manager removeItemAtPath:staged error:nil];
    return ok ? 1 : error_out(failure.localizedDescription.UTF8String ?: "No shader presets in the downloaded archive.",error,capacity);
  }
}
