#include "DOLTextureStore.h"
#include "DOLTextureLabels.h"
#include <cassert>
int main(){@autoreleasepool{
  NSFileManager* fm=NSFileManager.defaultManager;
  NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString* user=[root stringByAppendingPathComponent:@"User"];NSString* pack=[root stringByAppendingPathComponent:@"GR8P69"];
  assert([fm createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([fm createDirectoryAtPath:pack withIntermediateDirectories:YES attributes:nil error:nil]);
  assert(!DOLTextureGame(nil));
  // Exercise runtime language selection, including regional Traditional Chinese.
  assert([DOLTextureText(@"regionMessage",@"zh-HK") isEqual:DOLTextureText(@"regionMessage",@"zh_Hant")]);
  assert(![DOLTextureText(@"regionMessage",@"zh-HK") isEqual:DOLTextureText(@"regionMessage",@"zh")]);
  for(NSString* locale in @[@"en",@"es",@"ru",@"zh",@"zh_Hant",@"pt",@"fr",@"de",@"it",@"id",@"ja",@"ko"]){
    NSString* warning=DOLTextureText(@"regionMessage",locale);
    assert([warning containsString:@"{source}"] && [warning containsString:@"{game}"]);
    assert(![DOLTextureText(@"regionImport",locale) isEqual:@"regionImport"]);
  }
  NSDictionary* empty=DOLTextureStatus(user,@"GR8P69",0);
  assert(![empty[@"enabled"] boolValue] && [empty[@"count"] intValue]==0);
  assert(DOLTextureStatus(user,nil,0).count==0);
  const unsigned char png[]={137,80,78,71,13,10,26,10};NSData* bytes=[NSData dataWithBytes:png length:sizeof(png)];
  assert([bytes writeToFile:[pack stringByAppendingPathComponent:@"tex1_a.png"] atomically:YES]);
  NSString* ini=DOLTextureINI(user,@"GR8P69",0);assert([fm createDirectoryAtPath:ini.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]);
  NSString* prior=@"[Gecko]\n$User code\n0429F040 3E8001CE\n[Video_Hacks]\nEFBToTextureEnable = True\n";assert([prior writeToFile:ini atomically:YES encoding:NSUTF8StringEncoding error:nil]);
  NSString* imported=DOLTextureImport([NSURL fileURLWithPath:pack],user,@"GR8P69",0);
  if(imported){
    NSLog(@"Texture import failed: %@; source=%@; attributes=%@; filesystem=%@",imported,pack,[fm attributesOfItemAtPath:pack error:nil],[fm attributesOfFileSystemForPath:user error:nil]);
    for(NSURL* entry in [fm enumeratorAtURL:[NSURL fileURLWithPath:pack] includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:nil])
      NSLog(@"entry=%@ values=%@",entry,[entry resourceValuesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLFileSizeKey] error:nil]);
  }
  assert(!imported);
  // Files/coordination can supply a directory URL with a trailing slash.
  assert(!DOLTextureImport([NSURL fileURLWithPath:[pack stringByAppendingString:@"/"] isDirectory:YES],user,@"GR8P69",0));
  NSDictionary* status=DOLTextureStatus(user,@"GR8P69",0);assert([status[@"enabled"] boolValue] && [status[@"count"] intValue]==1);
  NSString* written=[NSString stringWithContentsOfFile:ini encoding:NSUTF8StringEncoding error:nil];assert([written hasPrefix:prior]);assert([DOLIniValue(written,@"Video_Settings",@"CacheHiresTextures") isEqual:@"False"]);
  assert(DOLTextureEnable(user,@"GR8P69",0,NO));assert(![DOLTextureStatus(user,@"GR8P69",0)[@"enabled"] boolValue]);
  assert(DOLTextureImport([NSURL fileURLWithPath:pack],user,@"GR8E69",0));
  assert([[NSData dataWithContentsOfFile:[user stringByAppendingPathComponent:@"Load/Textures/GR8P69/tex1_a.png"]] isEqual:bytes]);
  // Reported Fire Emblem import: a GFEE01 pack was selected for a GFEP01 game.
  // The warning must name both identities and leave the previous pack intact.
  NSString* pal=[root stringByAppendingPathComponent:@"GFEP01"];
  NSString* usa=[root stringByAppendingPathComponent:@"GFEE01/Map and Battle"];
  assert([fm createDirectoryAtPath:pal withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([fm createDirectoryAtPath:usa withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([bytes writeToFile:[pal stringByAppendingPathComponent:@"tex1_before.png"] atomically:YES]);
  assert([bytes writeToFile:[usa stringByAppendingPathComponent:@"tex1_after.png"] atomically:YES]);
  assert(!DOLTextureImport([NSURL fileURLWithPath:pal],user,@"GFEP01",0));
  NSDictionary* region=nil;
  assert([DOLTextureImport([NSURL fileURLWithPath:usa.stringByDeletingLastPathComponent],user,@"GFEP01",0,NO,&region) isEqual:@"region"]);
  assert([region[@"gameId"] isEqual:@"GFEP01"] && [region[@"sourceGameIds"] isEqual:@[@"GFEE01"]]);
  NSString* target=[user stringByAppendingPathComponent:@"Load/Textures/GFEP01"];
  assert([[NSData dataWithContentsOfFile:[target stringByAppendingPathComponent:@"tex1_before.png"]] isEqual:bytes]);
  assert(!DOLTextureImport([NSURL fileURLWithPath:usa.stringByDeletingLastPathComponent],user,@"GFEP01",0,YES));
  assert([[NSData dataWithContentsOfFile:[target stringByAppendingPathComponent:@"Map and Battle/tex1_after.png"]] isEqual:bytes]);
  assert([DOLTextureStatus(user,@"GFEP01",0)[@"sourceGameIds"] isEqual:@[@"GFEE01"]]);
  // Explicit permission for another region never grants permission for another game.
  assert(DOLTextureImport([NSURL fileURLWithPath:pal],user,@"GR8P69",0,YES));
  NSString* family=[root stringByAppendingPathComponent:@"GFE/Portraits"];
  assert([fm createDirectoryAtPath:family withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([bytes writeToFile:[family stringByAppendingPathComponent:@"tex1_family.png"] atomically:YES]);
  assert(!DOLTextureImport([NSURL fileURLWithPath:family.stringByDeletingLastPathComponent],user,@"GFEP01",0));
  assert([[NSData dataWithContentsOfFile:[target stringByAppendingPathComponent:@"Portraits/tex1_family.png"]] isEqual:bytes]);
  assert([DOLTextureStatus(user,@"GFEP01",0)[@"sourceGameIds"] isEqual:@[@"GFE"]]);
  assert([[NSData dataWithContentsOfFile:[user stringByAppendingPathComponent:@"Load/Textures/GR8P69/tex1_a.png"]] isEqual:bytes]);
  NSString* link=[pack stringByAppendingPathComponent:@"tex1_link.png"];assert([fm createSymbolicLinkAtPath:link withDestinationPath:@"/etc/passwd" error:nil]);
  assert(DOLTextureImport([NSURL fileURLWithPath:pack],user,@"GR8P69",0));
  assert([[NSData dataWithContentsOfFile:[user stringByAppendingPathComponent:@"Load/Textures/GR8P69/tex1_a.png"]] isEqual:bytes]);
  [fm removeItemAtPath:root error:nil];puts("PASS HD store: exact game/revision; US-to-PAL warning preserves prior pack; confirmed import keeps hashes and provenance; region-free folders; unrelated games and settings preserved; preload off");
}}
