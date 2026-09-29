// SPDX-License-Identifier: GPL-3.0-or-later
// Host-side reversible GFX/GameINI trial. Never writes during gameplay.
#pragma once
#import <Foundation/Foundation.h>

static NSString* DOLTrim(NSString* s) { return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
static NSString* DOLSection(NSString* line) {
  NSString* s=DOLTrim(line); if(![s hasPrefix:@"["]) return nil;
  NSRange end=[s rangeOfString:@"]"]; if(end.location==NSNotFound)return nil;
  return [s substringWithRange:NSMakeRange(1,end.location-1)];
}
static NSArray* DOLKeyValue(NSString* line) {
  NSString* s=DOLTrim(line);if(!s.length || [s hasPrefix:@"#"] || [s hasPrefix:@";"])return nil;
  NSRange eq=[s rangeOfString:@"="];if(eq.location==NSNotFound)return nil;
  return @[DOLTrim([s substringToIndex:eq.location]),DOLTrim([s substringFromIndex:eq.location+1])];
}
static id DOLIniValue(NSString* text,NSString* section,NSString* key) {
  NSString* current=@"";id value=NSNull.null;
  for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
    NSString* next=DOLSection(line);if(next){current=next;continue;}
    NSArray* kv=DOLKeyValue(line);
    if([current caseInsensitiveCompare:section]==NSOrderedSame && kv && [kv[0] caseInsensitiveCompare:key]==NSOrderedSame)value=kv[1];
  }
  return value;
}
static NSString* DOLIniSet(NSString* text,NSString* section,NSString* key,id value) {
  NSMutableArray* out=[NSMutableArray array];NSString* current=@"";
  for(NSString* line in [text componentsSeparatedByString:@"\n"]) {
    NSString* next=DOLSection(line);if(next)current=next;
    NSArray* kv=next?nil:DOLKeyValue(line);
    if(kv && [current caseInsensitiveCompare:section]==NSOrderedSame && [kv[0] caseInsensitiveCompare:key]==NSOrderedSame)continue;
    [out addObject:line];
  }
  NSString* result=[out componentsJoinedByString:@"\n"];
  if(value!=NSNull.null)result=[result stringByAppendingFormat:@"\n[%@]\n%@ = %@\n",section,key,value];
  return result;
}
static BOOL DOLSafeTrialPath(NSString* p) {
  if(![p isKindOfClass:NSString.class] || [p containsString:@".."] || [p containsString:@"\\"] || [p hasPrefix:@"/"])return NO;
  if([p isEqual:@"Config/GFX.ini"])return YES;
  return [p rangeOfString:@"^GameSettings/[A-Z0-9]{4,6}(r[0-9]+)?\\.ini$" options:NSRegularExpressionSearch].location!=NSNotFound;
}
static NSString* DOLTrialJournal(NSString* user) {return [user stringByAppendingPathComponent:@"Config/NeoStationDisplayTrial362.json"];}
static BOOL DOLRestoreDisplayTrial(NSString* user) {
  if(!user.length)return YES;
  NSFileManager* fm=NSFileManager.defaultManager;NSString* journal=DOLTrialJournal(user);
  if(![fm fileExistsAtPath:journal])return YES;
  NSData* bytes=[NSData dataWithContentsOfFile:journal];
  if(!bytes || bytes.length>4194304)return NO;
  id data=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
  if(![data isKindOfClass:NSDictionary.class] || ![data[@"schema"] isEqual:@1] || ![data[@"files"] isKindOfClass:NSArray.class])return NO;
  // Validate all records BEFORE touching a file. Never follow a journal-supplied absolute path.
  for(id record in data[@"files"]) {
    if(![record isKindOfClass:NSDictionary.class] || !DOLSafeTrialPath(record[@"path"]) ||
       ![record[@"before"] isKindOfClass:NSString.class] || ![record[@"patched"] isKindOfClass:NSString.class] ||
       ![record[@"keys"] isKindOfClass:NSArray.class])return NO;
    for(id k in record[@"keys"])if(![k isKindOfClass:NSDictionary.class] ||
      ![@[@"Settings",@"Video_Settings"] containsObject:k[@"section"]] ||
      ![@[@"MTLUsePresentDrawable",@"ShaderCompilationMode"] containsObject:k[@"key"]] ||
      ![k[@"trial"] isKindOfClass:NSString.class] ||
      !(k[@"old"]==NSNull.null || [k[@"old"] isKindOfClass:NSString.class]))return NO;
  }
  for(NSDictionary* record in data[@"files"]) {
    NSString* file=[user stringByAppendingPathComponent:record[@"path"]];
    if(![fm fileExistsAtPath:file])continue;
    NSDictionary* attributes=[fm attributesOfItemAtPath:file error:nil];
    if([attributes[NSFileType] isEqual:NSFileTypeSymbolicLink])return NO;
    NSString* current=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];if(!current)return NO;
    NSString* restored=current;
    if([current isEqual:record[@"patched"]])restored=record[@"before"];
    else for(NSDictionary* key in record[@"keys"]) {
      // Preserve a user's intervening change to that setting rather than overwriting it.
      if([DOLIniValue(restored,key[@"section"],key[@"key"]) isEqual:key[@"trial"]])
        restored=DOLIniSet(restored,key[@"section"],key[@"key"],key[@"old"]);
    }
    if([restored isEqual:current])continue;
    if(![record[@"existed"] boolValue] && !DOLTrim(restored).length) {
      if(![fm removeItemAtPath:file error:nil])return NO;
    } else if(![restored writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:nil])return NO;
  }
  return [fm removeItemAtPath:journal error:nil];
}
static BOOL DOLBeginDisplayTrial(NSString* user,NSString* gameId,NSInteger profile) {
  if(!user.length || !DOLRestoreDisplayTrial(user))return NO;
  if(profile<0 || profile>2)return NO;
  NSFileManager* fm=NSFileManager.defaultManager;
  NSMutableArray<NSString*>* paths=[NSMutableArray arrayWithObject:@"Config/GFX.ini"];
  if(profile!=0 && gameId.length) {
    if([gameId rangeOfString:@"^[A-Z0-9]{4,6}$" options:NSRegularExpressionSearch].location==NSNotFound)return NO;
    NSString* folder=[user stringByAppendingPathComponent:@"GameSettings"];
    if(![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil])return NO;
    [paths addObject:[NSString stringWithFormat:@"GameSettings/%@.ini",gameId]];
    for(NSString* file in [fm contentsOfDirectoryAtPath:folder error:nil]) {
      NSString* pattern=[NSString stringWithFormat:@"^%@r[0-9]+\\.ini$",gameId];
      if([file rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound)
        [paths addObject:[@"GameSettings/" stringByAppendingString:file]];
    }
  }
  if(paths.count>64)return NO;
  NSMutableArray* records=[NSMutableArray array];
  for(NSString* relative in paths) {
    NSString* file=[user stringByAppendingPathComponent:relative];
    if(![fm createDirectoryAtPath:file.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil])return NO;
    BOOL exists=[fm fileExistsAtPath:file];NSDictionary* a=[fm attributesOfItemAtPath:file error:nil];
    if([a[NSFileType] isEqual:NSFileTypeSymbolicLink] || [a[NSFileSize] unsignedLongLongValue]>1048576)return NO;
    NSString* before=exists?[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil]:@"";
    if(!before)return NO;
    NSString* patched=before;NSMutableArray* keys=[NSMutableArray array];
    NSString* section=[relative hasPrefix:@"Config/"]?@"Settings":@"Video_Settings";
    NSMutableDictionary* requested=[NSMutableDictionary dictionary];
    if([relative hasPrefix:@"Config/"]) {
      // The pinned BaseConfigLoader::Load updates present keys but does not clear
      // keys omitted from disk. Seed original defaults too, or a previous hybrid
      // run could survive a rollback in the same NeoStation process.
      id originalMetal=DOLIniValue(before,section,@"MTLUsePresentDrawable");
      id originalShaders=DOLIniValue(before,section,@"ShaderCompilationMode");
      requested[@"MTLUsePresentDrawable"]=profile==0?(originalMetal==NSNull.null?@"2":originalMetal):@"1";
      requested[@"ShaderCompilationMode"]=profile==2?@"2":(originalShaders==NSNull.null?@"0":originalShaders);
    } else {
      requested[@"MTLUsePresentDrawable"]=@"1";
      if(profile==2)requested[@"ShaderCompilationMode"]=@"2";
    }
    for(NSString* key in [[requested allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      [keys addObject:@{@"section":section,@"key":key,@"old":DOLIniValue(before,section,key),@"trial":requested[key]}];
      patched=DOLIniSet(patched,section,key,requested[key]);
    }
    [records addObject:@{@"path":relative,@"existed":@(exists),@"before":before,@"patched":patched,@"keys":keys}];
  }
  NSData* journal=[NSJSONSerialization dataWithJSONObject:@{@"schema":@1,@"files":records} options:0 error:nil];
  if(!journal || journal.length>4194304 || ![journal writeToFile:DOLTrialJournal(user) options:NSDataWritingAtomic error:nil])return NO;
  for(NSDictionary* record in records)if(![record[@"patched"] writeToFile:[user stringByAppendingPathComponent:record[@"path"]] atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
    DOLRestoreDisplayTrial(user);return NO;
  }
  return YES;
}
