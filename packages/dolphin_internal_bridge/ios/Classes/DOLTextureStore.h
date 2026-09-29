// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "DolphinDisplayTrial.h"
#include "DOLTextureZip.h"

static BOOL DOLTextureGame(NSString* game) {
  return [game rangeOfString:@"^[A-Z0-9]{6}$" options:NSRegularExpressionSearch].location!=NSNotFound;
}
static NSString* DOLTextureINI(NSString* user,NSString* game,NSInteger revision) {
  if(!DOLTextureGame(game) || revision<0 || revision>65535)return nil;
  return [user stringByAppendingPathComponent:[NSString stringWithFormat:@"GameSettings/%@r%ld.ini",game,(long)revision]];
}
static BOOL DOLTextureSafeParents(NSString* path,NSString* user) {
  NSFileManager* fm=NSFileManager.defaultManager;
  if(![path hasPrefix:[user stringByAppendingString:@"/"]])return NO;
  for(NSString* current=path;current.length>=user.length;current=current.stringByDeletingLastPathComponent) {
    NSDictionary* a=[fm attributesOfItemAtPath:current error:nil];
    if([a[NSFileType] isEqual:NSFileTypeSymbolicLink])return NO;
    if([current isEqual:user])return YES;
  }
  return NO;
}
static BOOL DOLTextureEnable(NSString* user,NSString* game,NSInteger revision,BOOL enabled) {
  NSString* file=DOLTextureINI(user,game,revision);NSFileManager* fm=NSFileManager.defaultManager;
  if(!file || !DOLTextureSafeParents(file,user))return NO;
  NSDictionary* a=[fm attributesOfItemAtPath:file error:nil];if([a[NSFileSize] unsignedLongLongValue]>1048576)return NO;
  NSString* before=[fm fileExistsAtPath:file]?[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil]:@"";
  if(!before || ![fm createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil])return NO;
  NSString* patched=DOLIniSet(before,@"Video_Settings",@"HiresTextures",enabled?@"True":@"False");
  // Loading a whole HD pack into RAM defeats the mobile memory budget.
  patched=DOLIniSet(patched,@"Video_Settings",@"CacheHiresTextures",@"False");
  return [patched writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static NSDictionary* DOLTextureStatus(NSString* user,NSString* game,NSInteger revision) {
  NSString* ini=DOLTextureINI(user,game,revision);if(!ini || !DOLTextureSafeParents(ini,user))return @{};
  NSString* text=[NSString stringWithContentsOfFile:ini encoding:NSUTF8StringEncoding error:nil]?:@"";
  NSString* folder=[user stringByAppendingPathComponent:[@"Load/Textures/" stringByAppendingString:game]];
  NSDictionary* manifest=nil;
  if(DOLTextureSafeParents(folder,user)){
    NSData* data=[NSData dataWithContentsOfFile:[folder stringByAppendingPathComponent:@"NeoStation-pack.json"]];
    if(data.length<65536)manifest=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  }
  if(![manifest isKindOfClass:NSDictionary.class])manifest=@{};
  return @{@"enabled":@([DOLIniValue(text,@"Video_Settings",@"HiresTextures") isEqual:@"True"]),
    @"count":manifest[@"count"]?:@0,@"bytes":manifest[@"bytes"]?:@0};
}
static BOOL DOLTextureSignature(NSString* path) {
  NSFileHandle* file=[NSFileHandle fileHandleForReadingAtPath:path];if(!file)return NO;
  NSData* data=[file readDataOfLength:8];[file closeFile];
  const unsigned char png[]={137,80,78,71,13,10,26,10};
  return ([path.pathExtension isEqual:@"png"] && data.length==8 && !memcmp(data.bytes,png,8)) ||
    ([path.pathExtension isEqual:@"dds"] && data.length>=4 && !memcmp(data.bytes,"DDS ",4));
}
// Work only in a new private staging directory. An error never replaces a
// working pack, changes cheats, or extracts paths supplied by an archive verbatim.
static NSString* DOLTextureImport(NSURL* url,NSString* user,NSString* game,NSInteger revision) {
  if(!DOLTextureGame(game) || !DOLTextureINI(user,game,revision))return @"invalid";
  NSFileManager* fm=NSFileManager.defaultManager;
  NSString* parent=[user stringByAppendingPathComponent:@"Load/Textures"];
  if(!DOLTextureSafeParents(parent,user) || ![fm createDirectoryAtPath:parent withIntermediateDirectories:YES attributes:nil error:nil])return @"failed";
  NSString* stage=[parent stringByAppendingPathComponent:[@".import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(![fm createDirectoryAtPath:stage withIntermediateDirectories:NO attributes:nil error:nil])return @"failed";
  __block NSString* failure=@"invalid";__block uint64_t total=0;__block NSUInteger count=0;
  BOOL scoped=[url startAccessingSecurityScopedResource];__block NSError* coordination=nil;
  NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateReadingItemAtURL:url options:0 error:&coordination byAccessor:^(NSURL* source){
    NSDictionary* attrs=[fm attributesOfItemAtPath:source.path error:nil];
    if([attrs[NSFileType] isEqual:NSFileTypeSymbolicLink])return;
    if([attrs[NSFileType] isEqual:NSFileTypeDirectory]) {
      NSMutableArray* plan=[NSMutableArray array];NSMutableSet* names=[NSMutableSet set];
      __block BOOL readFailed=NO;
      NSDirectoryEnumerator* enumerator=[fm enumeratorAtURL:source includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLFileSizeKey] options:0 errorHandler:^BOOL(NSURL* bad,NSError* error){readFailed=YES;return NO;}];
      NSUInteger visited=0;
      for(NSURL* entry in enumerator) {
        if(++visited>40000)return;
        NSDictionary* v=[entry resourceValuesForKeys:@[NSURLIsSymbolicLinkKey,NSURLIsRegularFileKey,NSURLFileSizeKey] error:nil];
        if(!v || [v[NSURLIsSymbolicLinkKey] boolValue])return;
        if(![v[NSURLIsRegularFileKey] boolValue])continue;
        NSString* path=[source.lastPathComponent stringByAppendingPathComponent:[entry.path substringFromIndex:source.path.length+1]];
        auto relative=DOLTextures::relative(path.UTF8String,game.UTF8String);if(relative.empty())continue;
        NSString* dest=[NSString stringWithUTF8String:relative.c_str()];uint64_t size=[v[NSURLFileSizeKey] unsignedLongLongValue];
        if(!size || size>DOLTextures::maxFile || [names containsObject:dest.lowercaseString] || plan.count>=20000)return;
        total+=size;if(total>DOLTextures::maxPack)return;[names addObject:dest.lowercaseString];[plan addObject:@[entry,dest]];
      }
      if(readFailed || !enumerator || !plan.count)return;
      uint64_t free=[[[fm attributesOfFileSystemForPath:parent error:nil] objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
      if(free<total+1024ULL*1024*1024){failure=@"space";return;}
      for(NSArray* item in plan) {
        NSString* dest=[stage stringByAppendingPathComponent:item[1]];
        if(![fm createDirectoryAtPath:dest.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil] ||
           ![fm copyItemAtURL:item[0] toURL:[NSURL fileURLWithPath:dest] error:nil] || !DOLTextureSignature(dest)){failure=@"failed";return;}
        ++count;
      }
    } else if([source.pathExtension.lowercaseString isEqual:@"zip"]) {
      std::ifstream input(source.path.fileSystemRepresentation,std::ios::binary);std::vector<DOLTextures::File> files;
      if(!DOLTextures::list(input,game.UTF8String,files,total))return;
      uint64_t free=[[[fm attributesOfFileSystemForPath:parent error:nil] objectForKey:NSFileSystemFreeSize] unsignedLongLongValue];
      if(free<total+1024ULL*1024*1024){failure=@"space";return;}
      for(const auto& file:files) {
        NSString* relative=[NSString stringWithUTF8String:file.relative.c_str()];if(!relative){failure=@"invalid";return;}
        NSString* dest=[stage stringByAppendingPathComponent:relative];
        if(!dest || !DOLTextures::extract(input,file,dest.fileSystemRepresentation) || !DOLTextureSignature(dest)){failure=@"failed";return;}++count;
      }
    } else return;
    failure=nil;
  }];
  if(scoped)[url stopAccessingSecurityScopedResource];
  if(coordination || failure || !count){[fm removeItemAtPath:stage error:nil];return failure?:@"failed";}
  NSData* manifest=[NSJSONSerialization dataWithJSONObject:@{@"gameId":game,@"revision":@(revision),@"count":@(count),@"bytes":@(total)} options:0 error:nil];
  if(![manifest writeToFile:[stage stringByAppendingPathComponent:@"NeoStation-pack.json"] atomically:YES]){[fm removeItemAtPath:stage error:nil];return @"failed";}
  NSString* target=[parent stringByAppendingPathComponent:game];NSString* backup=[parent stringByAppendingPathComponent:[@".previous-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  if(!DOLTextureSafeParents(target,user)){[fm removeItemAtPath:stage error:nil];return @"failed";}
  BOOL existed=[fm fileExistsAtPath:target];
  if(existed && ![fm moveItemAtPath:target toPath:backup error:nil]){[fm removeItemAtPath:stage error:nil];return @"failed";}
  BOOL moved=[fm moveItemAtPath:stage toPath:target error:nil];
  if(!moved || !DOLTextureEnable(user,game,revision,YES)){
    if(moved)[fm removeItemAtPath:target error:nil];
    if(existed)[fm moveItemAtPath:backup toPath:target error:nil];
    [fm removeItemAtPath:stage error:nil];return @"failed";
  }
  if(existed)[fm removeItemAtPath:backup error:nil];return nil;
}
