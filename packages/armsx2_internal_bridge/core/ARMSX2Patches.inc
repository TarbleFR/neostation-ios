int get_available_patches_json(char* output,size_t capacity) {
  if(!output || capacity<2 || !has_running_game()) return 0;
  NSData* encoded=nil;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      const std::string serial=VMManager::GetDiscSerial();
      const u32 crc=VMManager::GetDiscCRC();
      if(serial.empty() || crc==0) return;

      u32 unlabelled=0;
      NSMutableArray* items=[NSMutableArray array];
      for(const bool cheats : {false, true}) {
      u32 unlabelledInSource=0;
      const std::vector<Patch::PatchInfo> patches=
          Patch::GetPatchInfo(serial,crc,cheats,false,&unlabelledInSource);
      unlabelled+=unlabelledInSource;
      NSString* section=[NSString stringWithUTF8String:cheats ?
          Patch::CHEATS_CONFIG_SECTION : Patch::PATCHES_CONFIG_SECTION];
      NSString* enableKey=[NSString stringWithUTF8String:Patch::PATCH_ENABLE_CONFIG_KEY];
      NSString* disableKey=[NSString stringWithUTF8String:Patch::PATCH_DISABLE_CONFIG_KEY];
      NSSet<NSString*>* enabled=[NSSet setWithArray:
          [ARMSX2Bridge patchEnableListForISO:nil section:section key:enableKey]];
      NSSet<NSString*>* disabled=[NSSet setWithArray:
          [ARMSX2Bridge patchEnableListForISO:nil section:section key:disableKey]];

      for(const Patch::PatchInfo& patch:patches) {
        if(patch.name.empty()) continue;
        NSString* name=[NSString stringWithUTF8String:patch.name.c_str()];
        if(!name.length) continue;
        const BOOL toggleable=!cheats && Patch::IsGloballyToggleablePatch(patch);
        NSInteger state=0;
        if([enabled containsObject:name]) state=1;
        else if(toggleable && ![disabled containsObject:name]) state=-1;
        NSString* description=patch.description.empty() ? @"" :
            [NSString stringWithUTF8String:patch.description.c_str()];
        NSString* author=patch.author.empty() ? @"" :
            [NSString stringWithUTF8String:patch.author.c_str()];
        // Opaque, typed selection: identical names in cheats/ and patches/
        // must never toggle each other. Legacy callers may still pass a name.
        NSData* selection=[NSJSONSerialization dataWithJSONObject:@[@(cheats),name]
            options:0 error:nil];
        NSString* identifier=[@"neo-patch-v1:" stringByAppendingString:
            [[[NSString alloc] initWithData:selection encoding:NSUTF8StringEncoding] autorelease]];
        [items addObject:@{
          @"id":identifier,
          @"cheat":@(cheats),
          @"name":name,
          @"description":description ?: @"",
          @"author":author ?: @"",
          @"value":@(state),
          @"automatic":@(toggleable),
          @"place":@((int)(patch.place.has_value() ? patch.place.value() : Patch::PPT_END_MARKER)),
        }];
      }
      if(unlabelledInSource) {
        [items addObject:@{
          @"name":@"", @"unlabelled":@(unlabelledInSource),
          @"cheat":@(cheats), @"readOnly":@YES,
        }];
      }
      }

      NSString* serialString=[NSString stringWithUTF8String:serial.c_str()] ?: @"";
      NSDictionary* payload=@{
        @"available":@YES,
        @"serial":serialString,
        @"crc":[NSString stringWithFormat:@"%08X",(unsigned int)crc],
        @"unlabelled":@(unlabelled),
        @"activePatches":@(Patch::GetActivePatchesCount()),
        @"activeCheats":@(Patch::GetActiveCheatsCount()),
        @"masterEnabled":@(EmuConfig.EnableCheats),
        @"hardcore":@(Achievements::IsHardcoreModeActive()),
        @"items":items,
      };
      encoded=[[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil] retain];
    }
  },true);
  if(!encoded) return 0;
  const BOOL fits=encoded.length+1<=capacity;
  if(fits) { memcpy(output,encoded.bytes,encoded.length); output[encoded.length]=0; }
  [encoded release];
  return fits ? 1 : 0;
}

int set_patch_state(const char* patch_name,int state,char* error,size_t capacity) {
  if(!patch_name || !patch_name[0] || (state < -1 || state > 1))
    return error_out("Unsupported ARMSX2 patch or state.",error,capacity);
  if(!has_running_game())
    return error_out("ARMSX2 patches require a running game.",error,capacity);

  std::string wanted(patch_name);
  bool cheats=false;
  constexpr std::string_view prefix="neo-patch-v1:";
  if(wanted.starts_with(prefix)) {
    NSData* data=[NSData dataWithBytes:wanted.data()+prefix.size()
        length:wanted.size()-prefix.size()];
    id selection=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if(![selection isKindOfClass:NSArray.class] || [selection count]!=2 ||
        ![selection[0] isKindOfClass:NSNumber.class] ||
        ![selection[1] isKindOfClass:NSString.class])
      return error_out("Invalid ARMSX2 patch selection.",error,capacity);
    cheats=[selection[0] boolValue];
    wanted=[selection[1] UTF8String];
  }
  BOOL success=NO;
  BOOL unsupportedAutomatic=NO;
  Host::RunOnCPUThread([&]{
    @autoreleasepool {
      const std::string serial=VMManager::GetDiscSerial();
      const u32 crc=VMManager::GetDiscCRC();
      if(serial.empty() || crc==0) return;

      u32 ignored=0;
      const std::vector<Patch::PatchInfo> patches=
          Patch::GetPatchInfo(serial,crc,cheats,false,&ignored);
      const auto found=std::find_if(patches.begin(),patches.end(),
          [&](const Patch::PatchInfo& patch){return patch.name==wanted;});
      if(found==patches.end()) return;

      if(cheats && state==1 && Achievements::IsHardcoreModeActive()) return;
      const BOOL toggleable=!cheats && Patch::IsGloballyToggleablePatch(*found);
      if(state==-1 && !toggleable) {
        unsupportedAutomatic=YES;
        return;
      }

      NSString* name=[NSString stringWithUTF8String:wanted.c_str()];
      NSString* section=[NSString stringWithUTF8String:cheats ?
          Patch::CHEATS_CONFIG_SECTION : Patch::PATCHES_CONFIG_SECTION];
      NSString* enableKey=[NSString stringWithUTF8String:Patch::PATCH_ENABLE_CONFIG_KEY];
      NSString* disableKey=[NSString stringWithUTF8String:Patch::PATCH_DISABLE_CONFIG_KEY];
      NSMutableArray<NSString*>* enabled=[[
          ARMSX2Bridge patchEnableListForISO:nil section:section key:enableKey] mutableCopy];
      NSMutableArray<NSString*>* disabled=[[
          ARMSX2Bridge patchEnableListForISO:nil section:section key:disableKey] mutableCopy];
      [enabled removeObject:name];
      [disabled removeObject:name];
      if(state==1) [enabled addObject:name];
      else if(state==0 && toggleable) [disabled addObject:name];

      [ARMSX2Bridge setPatchEnableList:enabled forISO:nil section:section key:enableKey];
      [ARMSX2Bridge setPatchEnableList:disabled forISO:nil section:section key:disableKey];
      [enabled release];
      [disabled release];

      if(cheats && state==1)
        [ARMSX2Bridge setPerGameINIBool:@"EmuCore" key:@"EnableCheats" value:YES forISO:nil];

      // The upstream list writer only saves the INI. Refresh the settings
      // layer before Patch reads Host::GetStringListSetting, otherwise the UI
      // changes but the old in-memory enable list remains active until reboot.
      VMManager::ReloadGameSettings();
      Patch::ReloadPatches(serial,crc,true,true,true,true);
      Patch::UpdateActivePatches(true,true,true,true);
      success=YES;
    }
  },true);
  if(unsupportedAutomatic)
    return error_out("Automatic is only available for globally toggleable ARMSX2 patches.",error,capacity);
  return success ? 1 :
      error_out("ARMSX2 could not update this game's patch.",error,capacity);
}
