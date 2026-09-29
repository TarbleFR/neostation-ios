#include "DOLTextureStore.h"
#include <cassert>
int main(){@autoreleasepool{
  NSFileManager* fm=NSFileManager.defaultManager;
  NSString* root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSString* user=[root stringByAppendingPathComponent:@"User"];NSString* pack=[root stringByAppendingPathComponent:@"GR8P69"];
  assert([fm createDirectoryAtPath:user withIntermediateDirectories:YES attributes:nil error:nil]);
  assert([fm createDirectoryAtPath:pack withIntermediateDirectories:YES attributes:nil error:nil]);
  assert(!DOLTextureGame(nil));
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
  NSString* link=[pack stringByAppendingPathComponent:@"tex1_link.png"];assert([fm createSymbolicLinkAtPath:link withDestinationPath:@"/etc/passwd" error:nil]);
  assert(DOLTextureImport([NSURL fileURLWithPath:pack],user,@"GR8P69",0));
  assert([[NSData dataWithContentsOfFile:[user stringByAppendingPathComponent:@"Load/Textures/GR8P69/tex1_a.png"]] isEqual:bytes]);
  [fm removeItemAtPath:root error:nil];puts("PASS HD store: exact game/revision; preserves cheats and unrelated settings; preload off; failed pack cannot replace existing textures");
}}
