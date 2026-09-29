// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "NeoCheatParser.h"

static NSString* NeoString(const std::string& s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static NSString* NeoField(NSDictionary* d,NSString* key) { return [d[key] isKindOfClass:NSString.class]?d[key]:@""; }
static NSString* NeoCheatDisplayName(NSString* name) {
  NSArray<NSString*>* parts=[name componentsSeparatedByString:@"/"];
  if(parts.count>=4 && [parts[0] isEqual:@"NeoStation"] && parts[2].length==32)
    return [[parts subarrayWithRange:NSMakeRange(3,parts.count-3)] componentsJoinedByString:@"/"];
  if(parts.count>=3 && [parts[0] isEqual:@"NeoStation"])
    return [[parts subarrayWithRange:NSMakeRange(2,parts.count-2)] componentsJoinedByString:@"/"];
  return name;
}
static BOOL NeoRegex(NSString* text,NSString* pattern) {return [text rangeOfString:pattern options:NSRegularExpressionSearch].location!=NSNotFound;}
static NSDictionary* NeoCheatFailure(NSString* key) {return @{@"success":@NO,@"errorKey":key,@"added":@0};}
static BOOL NeoIdentityMatches(NSDictionary* requested,NSDictionary* current,BOOL ps2) {
  if(![current[@"available"] boolValue]) return NO;
  if(ps2) return [NeoField(requested,@"serial") isEqual:NeoField(current,@"serial")] &&
      [NeoField(requested,@"crc").uppercaseString isEqual:NeoField(current,@"crc").uppercaseString] &&
      NeoRegex(NeoField(current,@"crc"),@"^[0-9A-Fa-f]{8}$") && ![NeoField(current,@"crc") isEqual:@"00000000"];
  return NeoRegex(NeoField(current,@"gameId"),@"^[A-Z0-9]{4}([A-Z0-9]{2})?$") &&
      [NeoField(requested,@"gameId") isEqual:NeoField(current,@"gameId")] &&
      [requested[@"revision"] isKindOfClass:NSNumber.class] &&
      [requested[@"revision"] isEqual:current[@"revision"]];
}
static BOOL NeoFilenameMatches(NSString* filename,NSDictionary* current,BOOL ps2) {
  NSString* stem=filename.lastPathComponent.stringByDeletingPathExtension.uppercaseString;
  if(!stem.length) return YES; // pasted text has no file identity; the editor shows the current identity.
  if(ps2) {
    NSRegularExpression* r=[NSRegularExpression regularExpressionWithPattern:@"^(?:[A-Z]{4}-?[0-9]{5}_)?([0-9A-F]{8})(?:[-_].*)?$" options:0 error:nil];
    NSTextCheckingResult* m=[r firstMatchInString:stem options:0 range:NSMakeRange(0,stem.length)];
    if(m && ![[stem substringWithRange:[m rangeAtIndex:1]] isEqual:NeoField(current,@"crc").uppercaseString]) return NO;
    if(m && [stem containsString:@"_"]) {
      NSString* prefix=[stem componentsSeparatedByString:@"_"].firstObject;
      if(NeoRegex(prefix,@"^[A-Z]{4}-?[0-9]{5}$") && ![[prefix stringByReplacingOccurrencesOfString:@"-" withString:@""] isEqual:[NeoField(current,@"serial").uppercaseString stringByReplacingOccurrencesOfString:@"-" withString:@""]]) return NO;
    }
  } else {
    NSRegularExpression* r=[NSRegularExpression regularExpressionWithPattern:@"^([A-Z0-9]{6})(?:R([0-9]+))?$" options:0 error:nil];
    NSTextCheckingResult* m=[r firstMatchInString:stem options:0 range:NSMakeRange(0,stem.length)];
    if(m) {
      if(![[stem substringWithRange:[m rangeAtIndex:1]] isEqual:NeoField(current,@"gameId")]) return NO;
      if([m rangeAtIndex:2].location!=NSNotFound && [[stem substringWithRange:[m rangeAtIndex:2]] integerValue]!=[current[@"revision"] integerValue]) return NO;
    }
  }
  return YES;
}
static NSString* NeoEntriesINI(const std::vector<NeoCheat::Entry>& entries) {
  NSMutableString* out=[NSMutableString string];
  for(const auto& e:entries) {
    NSString* section=e.type=="gecko"?@"Gecko":@"ActionReplay";
    [out appendFormat:@"\n[%@]\n$%@%@\n",section,NeoString(e.name),e.creator.empty()?@"":[NSString stringWithFormat:@" [%@]",NeoString(e.creator)]];
    for(const auto& line:e.lines) [out appendFormat:@"%@\n",NeoString(line)];
    if(e.type=="gecko") for(const auto& note:e.notes) [out appendFormat:@"*%@\n",NeoString(note)];
  }
  return out;
}
static NSDictionary* NeoDolphinImport(NSString* userDirectory,NSDictionary* request,NSDictionary* snapshot,BOOL skipDuplicates) {
  if(!userDirectory.length || !NeoIdentityMatches(request,snapshot,NO)) return NeoCheatFailure(@"sessionChanged");
  if([snapshot[@"hardcore"] boolValue]) return NeoCheatFailure(@"hardcore");
  if(!NeoFilenameMatches(NeoField(request,@"filename"),snapshot,NO)) return NeoCheatFailure(@"wrongGame");
  const auto parsed=NeoCheat::parse([NeoField(request,@"content") UTF8String],[NeoField(request,@"type") UTF8String],[NeoField(request,@"name") UTF8String],[NeoField(request,@"creator") UTF8String]);
  if(!parsed) return NeoCheatFailure(@"invalidCode");
  NSMutableSet* known=[NSMutableSet set];
  for(NSString* key in @[@"gecko",@"actionReplay"]) {
    for(NSDictionary* item in snapshot[key]) [known addObject:[NSString stringWithFormat:@"%@:%@",key,NeoField(item,@"name")]];
  }
  std::vector<NeoCheat::Entry> incoming;
  for(const auto& e:parsed.entries) {
    if(e.type!="gecko" && e.type!="actionReplay") return NeoCheatFailure(@"invalidCode");
    NSString* name=NeoString(e.name);
    if(e.type=="actionReplay" && !e.creator.empty()) name=[name stringByAppendingFormat:@" [%@]",NeoString(e.creator)];
    NSString* key=[NSString stringWithFormat:@"%@:%@",NeoString(e.type),name];
    if([known containsObject:key]) {if(skipDuplicates)continue;return NeoCheatFailure(@"duplicateName");}
    [known addObject:key];incoming.push_back(e);
  }
  if(incoming.empty()) return @{@"success":@YES,@"added":@0};
  NSString* folder=[userDirectory stringByAppendingPathComponent:@"GameSettings"];
  NSString* target=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@r%@.ini",snapshot[@"gameId"],snapshot[@"revision"]]];
  NSFileManager* fm=NSFileManager.defaultManager; NSError* error=nil;
  if(![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error]) return NeoCheatFailure(@"writeFailed");
  NSData* previous=[NSData dataWithContentsOfFile:target];
  if([fm fileExistsAtPath:target] && !previous) return NeoCheatFailure(@"writeFailed");
  if(previous.length>1048576) return NeoCheatFailure(@"writeFailed");
  NSString* old=previous?[[NSString alloc] initWithData:previous encoding:NSUTF8StringEncoding]:@"";
  if(!old) return NeoCheatFailure(@"writeFailed");
  NSMutableString* result=[old mutableCopy];
  [result appendString:@"\n# NeoStation: validated import; new entries start disabled.\n"];
  [result appendString:NeoEntriesINI(incoming)];
  for(const auto& e:incoming) {
    NSString* section=e.type=="gecko"?@"Gecko":@"ActionReplay";
    NSString* name=NeoString(e.name);
    if(e.type=="actionReplay" && !e.creator.empty()) name=[name stringByAppendingFormat:@" [%@]",NeoString(e.creator)];
    [result appendFormat:@"\n[%@_Disabled]\n$%@\n",section,name];
  }
  // Write a recoverable copy and atomically publish. No existing INI section,
  // code, enabled state or unrelated per-game graphics setting is replaced.
  if(previous && ![previous writeToFile:[target stringByAppendingString:@".before-import.bak"] options:NSDataWritingAtomic error:&error]) return NeoCheatFailure(@"writeFailed");
  if(![[result dataUsingEncoding:NSUTF8StringEncoding] writeToFile:target options:NSDataWritingAtomic error:&error]) return NeoCheatFailure(@"writeFailed");
  return @{@"success":@YES,@"added":@(incoming.size()),@"file":target};
}
static NSDictionary* NeoPnachImport(NSString* dataDirectory,NSDictionary* request,NSDictionary* snapshot) {
  if(!dataDirectory.length || !NeoIdentityMatches(request,snapshot,YES)) return NeoCheatFailure(@"sessionChanged");
  if([snapshot[@"hardcore"] boolValue]) return NeoCheatFailure(@"hardcore");
  if(!NeoFilenameMatches(NeoField(request,@"filename"),snapshot,YES)) return NeoCheatFailure(@"wrongGame");
  const auto parsed=NeoCheat::parse([NeoField(request,@"content") UTF8String],"pnach",[NeoField(request,@"name") UTF8String],[NeoField(request,@"creator") UTF8String]);
  if(!parsed) return NeoCheatFailure(@"invalidCode");
  NSString* crc=NeoField(snapshot,@"crc").uppercaseString;
  NSMutableString* content=[NSMutableString stringWithFormat:@"// NeoStation manual cheats; serial %@; CRC %@. Disabled until selected.\n",NeoField(snapshot,@"serial"),crc];
  NSMutableSet* names=[NSMutableSet set];
  for(const auto& entry:parsed.entries) {
    NSString* name=[NSString stringWithFormat:@"NeoStation/%@/%@",crc,NeoString(entry.name)];
    if([names containsObject:name]) return NeoCheatFailure(@"duplicateName");
    [names addObject:name];
    [content appendFormat:@"\n[%@]\n",name];
    if(!entry.creator.empty()) [content appendFormat:@"author=%@\n",NeoString(entry.creator)];
    for(const auto& line:entry.lines) [content appendFormat:@"%@\n",NeoString(line)];
  }
  NSData* bytes=[content dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,hash);
  NSMutableString* digest=[NSMutableString string];for(int i=0;i<12;i++)[digest appendFormat:@"%02x",hash[i]];
  NSString* folder=[dataDirectory stringByAppendingPathComponent:@"cheats"];
  // CRC-only prefix intentionally avoids upstream's serial_*.pnach wildcard
  // (which also loads other revisions). Never use the 00000000 wildcard.
  NSString* target=[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@-NeoStation-%@.pnach",crc,digest]];
  NSFileManager* fm=NSFileManager.defaultManager;NSError* error=nil;
  if([fm fileExistsAtPath:target]) return @{@"success":@YES,@"added":@0};
  for(NSDictionary* item in snapshot[@"items"]) {
    NSString* comparable=[NSString stringWithFormat:@"NeoStation/%@/%@",crc,NeoCheatDisplayName(NeoField(item,@"name"))];
    if([item[@"cheat"] boolValue] && [names containsObject:comparable]) return NeoCheatFailure(@"duplicateName");
  }
  // A previously deleted file can leave a name in PCSX2's Enable list. Give a
  // fresh import a unique group identity so it cannot inherit that enabled state.
  // Keep the deterministic filename for exact-content duplicate detection.
  NSString* token=[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""];
  NSString* prefix=[NSString stringWithFormat:@"[NeoStation/%@/",crc];
  NSString* unique=[NSString stringWithFormat:@"[NeoStation/%@/%@/",crc,token];
  bytes=[[content stringByReplacingOccurrencesOfString:prefix withString:unique] dataUsingEncoding:NSUTF8StringEncoding];
  if(![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:&error] || ![bytes writeToFile:target options:NSDataWritingAtomic error:&error]) return NeoCheatFailure(@"writeFailed");
  return @{@"success":@YES,@"added":@(parsed.entries.size()),@"file":target};
}
