// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include "NeoCheatParser.h"
#include "NeoCheatDocument.h"
#include <map>
#include <set>
#include <cstring>

static NSString* NeoString(const std::string& s) { return [[NSString alloc] initWithBytes:s.data() length:s.size() encoding:NSUTF8StringEncoding] ?: @""; }
static std::string NeoUTF8(NSString* text) {
  NSData* data=[text dataUsingEncoding:NSUTF8StringEncoding];
  return data.length?std::string(static_cast<const char*>(data.bytes),data.length):std::string{};
}
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
// The same immutable parsed list drives the preview and the final single write.
static NSArray* NeoCheatEntryPreview(const std::vector<NeoCheat::Entry>& entries) {
  NSMutableArray* result=[NSMutableArray arrayWithCapacity:entries.size()];
  for(const auto& entry:entries) {
    NSMutableArray* lines=[NSMutableArray arrayWithCapacity:entry.lines.size()];
    for(const auto& line:entry.lines)[lines addObject:NeoString(line)];
    [result addObject:@{@"name":NeoString(entry.name),@"creator":NeoString(entry.creator),
        @"type":NeoString(entry.type),@"lines":lines,@"lineCount":@(entry.lines.size())}];
  }
  return result;
}
static NSString* NeoEntriesPNACH(const std::vector<NeoCheat::Entry>& entries) {
  NSMutableString* text=[NSMutableString string];
  for(const auto& entry:entries) {
    [text appendFormat:@"\n[%@]\n",NeoString(entry.name)];
    if(!entry.creator.empty())[text appendFormat:@"author=%@\n",NeoString(entry.creator)];
    for(const auto& note:entry.notes)[text appendFormat:@"// %@\n",NeoString(note)];
    for(const auto& line:entry.lines)[text appendFormat:@"%@\n",NeoString(line)];
  }
  return text;
}
static NSDictionary* NeoParserFailure(const NeoCheat::Result& parsed);
// Shared by document picker tests and both native editors. File read failures,
// encodings and unsupported binary formats must not look like invalid code.
static NSDictionary* NeoDecodeCheatDocument(NSData* data,NSString* filename,NSDictionary* identity,BOOL ps2,NSString* fallback) {
  if(!data.length)return NeoCheatFailure(@"emptyFile");
  if(data.length>262144)return NeoCheatFailure(@"fileTooLarge");
  if(!NeoFilenameMatches(filename,identity,ps2))return NeoCheatFailure(@"wrongGame");
  NSString* ext=filename.pathExtension.lowercaseString;
  NSString* text=nil;NSString* type=nil;
  const auto* bytes=static_cast<const unsigned char*>(data.bytes);
  if([ext isEqual:@"gct"] && !ps2) {
    const unsigned char header[]={0x00,0xD0,0xC0,0xDE,0x00,0xD0,0xC0,0xDE};
    const unsigned char ending[]={0xF0,0,0,0,0,0,0,0};
    if(data.length<24 || data.length%8 || memcmp(bytes,header,8) || memcmp(bytes+data.length-8,ending,8))return NeoCheatFailure(@"invalidGct");
    NSMutableString* lines=[NSMutableString string];
    for(NSUInteger i=8;i<data.length-8;i+=8) {
      [lines appendFormat:@"%02X%02X%02X%02X %02X%02X%02X%02X\n",bytes[i],bytes[i+1],bytes[i+2],bytes[i+3],bytes[i+4],bytes[i+5],bytes[i+6],bytes[i+7]];
    }
    text=lines;type=@"gecko";
  } else {
    NSArray* allowed=ps2?@[@"pnach",@"txt"]:@[@"ini",@"txt",@"ar",@"gecko",@"dolphin",@""];
    if(![allowed containsObject:ext])return NeoCheatFailure(@"unsupportedFile");
    if(data.length>=2 && bytes[0]==0xFF && bytes[1]==0xFE)text=[[NSString alloc] initWithData:data encoding:NSUTF16LittleEndianStringEncoding];
    else if(data.length>=2 && bytes[0]==0xFE && bytes[1]==0xFF)text=[[NSString alloc] initWithData:data encoding:NSUTF16BigEndianStringEncoding];
    else text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if(!text)return NeoCheatFailure(@"fileEncoding");
    text=NeoString(NeoCheat::normalizeText(NeoUTF8(text)));
    if([text rangeOfString:@"<!doctype" options:NSCaseInsensitiveSearch].location!=NSNotFound ||
        [text rangeOfString:@"<html" options:NSCaseInsensitiveSearch].location!=NSNotFound) return NeoCheatFailure(@"unsupportedFile");
    type=ps2?@"pnach":[ext isEqual:@"ar"]?@"actionReplay":fallback?:@"gecko";
    if([ext isEqual:@"ini"] || [ext isEqual:@"dolphin"])type=@"ini";
    else if(!ps2 && [type isEqual:@"ini"])type=@"gecko"; // Previous file's canonical INI is not the next TXT's source format.
  }
  if(![text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length)return NeoCheatFailure(@"emptyFile");
  NSString* stem=filename.lastPathComponent.stringByDeletingPathExtension;
  if(!NeoCheat::safeName(NeoUTF8(stem)))stem=@"Imported cheat";
  const auto parsed=NeoCheat::parseDocument(NeoUTF8(text),NeoUTF8(type),NeoUTF8(stem),{},
      ps2?std::string{}:NeoUTF8(NeoField(identity,@"gameId")));
  if(!parsed)return NeoParserFailure(parsed);
  // Keep the existing single raw-code editor (including encrypted AR imports).
  // A titled file instead becomes a canonical list, not one giant pasted cheat.
  BOOL rawOnly=parsed.entries.size()==1;
  for(NSString* row in [text componentsSeparatedByString:@"\n"]) {
    const auto line=NeoCheat::trim(NeoUTF8(row));if(line.empty())continue;
    std::string normalized;
    const bool valid=ps2?NeoCheat::pnachLine(line,&normalized):
        NeoCheat::rawLine(line,&normalized) ||
        (NeoCheat::documentEncryptedShape(line) && NeoCheat::encryptedLine(line,&normalized));
    if(!valid){rawOnly=NO;break;}
  }
  if(rawOnly)type=NeoString(parsed.entries[0].type);
  else {text=ps2?NeoEntriesPNACH(parsed.entries):NeoEntriesINI(parsed.entries);type=ps2?@"pnach":@"ini";}
  // Prove the canonical file preserves all parsed titles and every code line.
  const auto canonical=NeoCheat::parse(NeoUTF8(text),NeoUTF8(type),NeoUTF8(stem));
  if(!canonical)return NeoParserFailure(canonical);
  if(canonical.entries.size()!=parsed.entries.size())return NeoCheatFailure(@"invalidCode");
  for(size_t i=0;i<parsed.entries.size();++i)
    if(canonical.entries[i].lines!=parsed.entries[i].lines || canonical.entries[i].type!=parsed.entries[i].type ||
        (!rawOnly && canonical.entries[i].name!=parsed.entries[i].name))return NeoCheatFailure(@"invalidCode");
  return @{@"success":@YES,@"content":text,@"type":type,@"filename":filename?:@"",
      @"entries":NeoCheatEntryPreview(parsed.entries),@"count":@(parsed.entries.size()),
      @"hasTitles":@(!rawOnly),@"warningKey":[ext isEqual:@"gct"]?@"gctCombined":@""};
}
static NSDictionary* NeoParserFailure(const NeoCheat::Result& parsed) {
  NSString* key=parsed.error=="identity"?@"wrongGame":parsed.error=="emptyBlock"?@"emptyBlock":parsed.error=="name"?@"nameRequired":parsed.error=="size"?@"fileTooLarge":parsed.error=="empty"?@"emptyFile":parsed.error=="mixedFormat"?@"mixedFormat":@"invalidCode";
  return @{@"success":@NO,@"errorKey":key,@"errorLine":@(parsed.line),@"added":@0};
}

// Preserve every unrelated byte/section. Empty sections are harmless to Dolphin
// and PCSX2; retaining their headers avoids rewriting unrelated preferences.
static NSString* NeoRemoveCheatBlock(NSString* source,NSString* type,NSString* name,BOOL ps2,BOOL* removed) {
  NSArray* lines=[source componentsSeparatedByString:@"\n"];
  NSMutableArray* keep=[NSMutableArray array];NSString* section=@"";BOOL deleting=NO;
  *removed=NO;
  NSString* wanted=[type isEqual:@"gecko"]?@"Gecko":@"ActionReplay";
  for(NSString* raw in lines) {
    NSString* line=[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if([line hasPrefix:@"["] && [line containsString:@"]"]) {
      section=[line substringWithRange:NSMakeRange(1,[line rangeOfString:@"]"].location-1)];
      deleting=ps2 && [section isEqual:name];
      if(deleting){*removed=YES;continue;}
      [keep addObject:raw];continue;
    }
    if(!ps2 && [section isEqual:wanted] && [line hasPrefix:@"$"]) {
      NSString* title=[line substringFromIndex:1];
      if([type isEqual:@"gecko"] && [title containsString:@"["]) title=[[title componentsSeparatedByString:@"["].firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      deleting=[title isEqual:name];if(deleting)*removed=YES;
    }
    if(!ps2 && ([section isEqual:[wanted stringByAppendingString:@"_Enabled"]] || [section isEqual:[wanted stringByAppendingString:@"_Disabled"]]) && [line isEqual:[@"$" stringByAppendingString:name]])continue;
    if(!deleting)[keep addObject:raw];
  }
  return [keep componentsJoinedByString:@"\n"];
}
static NSDictionary* NeoCheatRemovalPlan(NSString* root,NSDictionary* request,NSDictionary* snapshot,BOOL ps2) {
  if(!NeoIdentityMatches(request,snapshot,ps2))return NeoCheatFailure(@"sessionChanged");
  NSString* name=NeoField(request,@"name");NSString* type=NeoField(request,@"type");
  if(!name.length || (!ps2 && ![@[@"gecko",@"actionReplay"] containsObject:type]))return NeoCheatFailure(@"notRemovable");
  NSString* folder=[root stringByAppendingPathComponent:ps2?@"cheats":@"GameSettings"];
  NSMutableArray<NSString*>* candidates=[NSMutableArray array];
  if(ps2) {
    NSString* prefix=[NeoField(snapshot,@"crc").uppercaseString stringByAppendingString:@"-NeoStation-"];
    if(![name hasPrefix:[NSString stringWithFormat:@"NeoStation/%@/",NeoField(snapshot,@"crc").uppercaseString]])return NeoCheatFailure(@"notRemovable");
    for(NSString* file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil])
      if([file hasPrefix:prefix] && [file.pathExtension isEqual:@"pnach"])[candidates addObject:[folder stringByAppendingPathComponent:file]];
  } else {
    [candidates addObject:[folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@r%@.ini",snapshot[@"gameId"],snapshot[@"revision"]]]];
  }
  NSDictionary* selected=nil;
  for(NSString* path in candidates) {
    if([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil][NSFileType] isEqual:NSFileTypeSymbolicLink])return NeoCheatFailure(@"notRemovable");
    NSData* previous=[NSData dataWithContentsOfFile:path];
    if(previous.length>1048576)continue;
    NSString* old=previous?[[NSString alloc] initWithData:previous encoding:NSUTF8StringEncoding]:nil;
    if(!old)continue;BOOL removed=NO;
    NSString* updated=NeoRemoveCheatBlock(old,type,name,ps2,&removed);
    if(!removed)continue;
    if(selected)return NeoCheatFailure(@"notRemovable"); // ambiguous duplicate: never guess a file.
    selected=@{@"success":@YES,@"file":path,@"previous":previous,@"replacement":[updated dataUsingEncoding:NSUTF8StringEncoding]};
  }
  return selected?:NeoCheatFailure(@"notRemovable");
}
static BOOL NeoCommitCheatRemoval(NSDictionary* plan) {
  if(![plan[@"success"] boolValue])return NO;
  NSString* path=plan[@"file"];NSData* previous=plan[@"previous"];
  if(![[NSData dataWithContentsOfFile:path] isEqual:previous])return NO;
  if(![previous writeToFile:[path stringByAppendingString:@".before-delete.bak"] options:NSDataWritingAtomic error:nil])return NO;
  if([path.pathExtension isEqual:@"pnach"]) {
    NSString* next=[[NSString alloc] initWithData:plan[@"replacement"] encoding:NSUTF8StringEncoding];
    if([next rangeOfString:@"(?m)^\\s*patch\\s*=" options:NSRegularExpressionSearch].location==NSNotFound) return [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  }
  return [plan[@"replacement"] writeToFile:path options:NSDataWritingAtomic error:nil];
}
// File imports de-duplicate by complete code, never silently replace a namesake.
static std::string NeoEntryKey(const NeoCheat::Entry& entry,BOOL ps2) {
  std::string name=entry.name;
  if(ps2)name=NeoUTF8(NeoCheatDisplayName(NeoString(name)));
  else if(entry.type=="actionReplay" && !entry.creator.empty())name+=" ["+entry.creator+"]";
  return (ps2?"pnach":entry.type)+":"+name;
}
struct NeoBatchSelection {
  std::vector<NeoCheat::Entry> entries;NSUInteger skipped=0;NSString* conflict=nil;
};
static NeoBatchSelection NeoSelectBatch(NSString* root,NSDictionary* snapshot,BOOL ps2,
                                       const std::vector<NeoCheat::Entry>& entries) {
  NeoBatchSelection selection;std::set<std::string> reserved,ambiguous;
  std::map<std::string,NeoCheat::Entry> known;
  if(ps2) {
    for(NSDictionary* item in snapshot[@"items"])if([item[@"cheat"] boolValue])
      reserved.insert("pnach:"+NeoUTF8(NeoCheatDisplayName(NeoField(item,@"name"))));
  } else {
    for(NSString* type in @[@"gecko",@"actionReplay"])
      for(NSDictionary* item in snapshot[type])reserved.insert(NeoUTF8(type)+":"+NeoUTF8(NeoField(item,@"name")));
  }
  NSString* folder=[root stringByAppendingPathComponent:ps2?@"cheats":@"GameSettings"];
  NSMutableArray<NSString*>* files=[NSMutableArray array];
  if(ps2) {
    NSString* prefix=[NeoField(snapshot,@"crc").uppercaseString stringByAppendingString:@"-NeoStation-"];
    for(NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil])
      if([name hasPrefix:prefix] && [name.pathExtension isEqual:@"pnach"])[files addObject:name];
  } else {
    [files addObject:[NSString stringWithFormat:@"%@.ini",snapshot[@"gameId"]]];
    [files addObject:[NSString stringWithFormat:@"%@r%@.ini",snapshot[@"gameId"],snapshot[@"revision"]]];
  }
  for(NSString* name in files) {
    NSString* file=[folder stringByAppendingPathComponent:name];
    NSDictionary* attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file error:nil];
    if(![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue]>1048576)continue;
    NSString* text=[NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
    if(!text)continue;
    if(ps2) {
      NSMutableArray* normalized=[NSMutableArray array];
      for(NSString* row in [text componentsSeparatedByString:@"\n"]) {
        NSString* line=[row stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if([line hasPrefix:@"[NeoStation/"] && [line hasSuffix:@"]"])
          [normalized addObject:[NSString stringWithFormat:@"[%@]",NeoCheatDisplayName([line substringWithRange:NSMakeRange(1,line.length-2)])]];
        else [normalized addObject:row];
      }
      text=[normalized componentsJoinedByString:@"\n"];
    }
    const auto parsed=NeoCheat::parse(NeoUTF8(text),ps2?"pnach":"ini","Stored");
    if(!parsed)continue; // Unknown existing data is never treated as an exact match.
    for(const auto& entry:parsed.entries) {
      const auto key=NeoEntryKey(entry,ps2);reserved.insert(key);
      const auto found=known.find(key);
      if(found!=known.end() && (found->second.lines!=entry.lines || found->second.encrypted!=entry.encrypted))ambiguous.insert(key);
      else known[key]=entry;
    }
  }
  for(const auto& entry:entries) {
    const auto key=NeoEntryKey(entry,ps2);const auto found=known.find(key);
    if(reserved.count(key)) {
      if(!ambiguous.count(key) && found!=known.end() && found->second.lines==entry.lines && found->second.encrypted==entry.encrypted) {
        ++selection.skipped;continue;
      }
      selection.conflict=NeoString(entry.name);selection.entries.clear();return selection;
    }
    reserved.insert(key);known[key]=entry;selection.entries.push_back(entry);
  }
  return selection;
}
static NSDictionary* NeoBatchConflict(NSString* name) {
  return @{@"success":@NO,@"errorKey":@"batchConflict",@"entryName":name?:@"",@"added":@0};
}
static NSDictionary* NeoDolphinImport(NSString* userDirectory,NSDictionary* request,NSDictionary* snapshot,BOOL skipDuplicates) {
  if(!userDirectory.length || !NeoIdentityMatches(request,snapshot,NO)) return NeoCheatFailure(@"sessionChanged");
  if([snapshot[@"hardcore"] boolValue]) return NeoCheatFailure(@"hardcore");
  if(!NeoFilenameMatches(NeoField(request,@"filename"),snapshot,NO)) return NeoCheatFailure(@"wrongGame");
  const auto parsed=NeoCheat::parse(NeoUTF8(NeoField(request,@"content")),[NeoField(request,@"type") UTF8String],[NeoField(request,@"name") UTF8String],[NeoField(request,@"creator") UTF8String]);
  if(!parsed) return NeoParserFailure(parsed);
  for(const auto& entry:parsed.entries)
    if(entry.type!="gecko" && entry.type!="actionReplay")return NeoCheatFailure(@"invalidCode");
  NSMutableSet* known=[NSMutableSet set];
  for(NSString* key in @[@"gecko",@"actionReplay"]) {
    for(NSDictionary* item in snapshot[key]) [known addObject:[NSString stringWithFormat:@"%@:%@",key,NeoField(item,@"name")]];
  }
  std::vector<NeoCheat::Entry> incoming;NSUInteger skipped=0;
  if([request[@"batchImport"] boolValue]) {
    const auto selection=NeoSelectBatch(userDirectory,snapshot,NO,parsed.entries);
    if(selection.conflict)return NeoBatchConflict(selection.conflict);
    incoming=selection.entries;skipped=selection.skipped;
  } else for(const auto& e:parsed.entries) {
    if(e.type!="gecko" && e.type!="actionReplay") return NeoCheatFailure(@"invalidCode");
    NSString* name=NeoString(e.name);
    if(e.type=="actionReplay" && !e.creator.empty()) name=[name stringByAppendingFormat:@" [%@]",NeoString(e.creator)];
    NSString* key=[NSString stringWithFormat:@"%@:%@",NeoString(e.type),name];
    if([known containsObject:key]) {if(skipDuplicates){++skipped;continue;}return NeoCheatFailure(@"duplicateName");}
    [known addObject:key];incoming.push_back(e);
  }
  if(incoming.empty()) return @{@"success":@YES,@"added":@0,@"skipped":@(skipped)};
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
  return @{@"success":@YES,@"added":@(incoming.size()),@"skipped":@(skipped),@"file":target};
}
static NSDictionary* NeoPnachImport(NSString* dataDirectory,NSDictionary* request,NSDictionary* snapshot) {
  if(!dataDirectory.length || !NeoIdentityMatches(request,snapshot,YES)) return NeoCheatFailure(@"sessionChanged");
  if([snapshot[@"hardcore"] boolValue]) return NeoCheatFailure(@"hardcore");
  if(!NeoFilenameMatches(NeoField(request,@"filename"),snapshot,YES)) return NeoCheatFailure(@"wrongGame");
  const auto parsed=NeoCheat::parse(NeoUTF8(NeoField(request,@"content")),"pnach",[NeoField(request,@"name") UTF8String],[NeoField(request,@"creator") UTF8String]);
  if(!parsed) return NeoParserFailure(parsed);
  std::vector<NeoCheat::Entry> incoming=parsed.entries;NSUInteger skipped=0;
  if([request[@"batchImport"] boolValue]) {
    const auto selection=NeoSelectBatch(dataDirectory,snapshot,YES,incoming);
    if(selection.conflict)return NeoBatchConflict(selection.conflict);
    incoming=selection.entries;skipped=selection.skipped;
    if(incoming.empty())return @{@"success":@YES,@"added":@0,@"skipped":@(skipped)};
  }
  NSString* crc=NeoField(snapshot,@"crc").uppercaseString;
  NSMutableString* content=[NSMutableString stringWithFormat:@"// NeoStation manual cheats; serial %@; CRC %@. Disabled until selected.\n",NeoField(snapshot,@"serial"),crc];
  NSMutableSet* names=[NSMutableSet set];
  for(const auto& entry:incoming) {
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
  if([fm fileExistsAtPath:target]) {
    if([request[@"batchImport"] boolValue])return NeoCheatFailure(@"writeFailed");
    return @{@"success":@YES,@"added":@0};
  }
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
  return @{@"success":@YES,@"added":@(incoming.size()),@"skipped":@(skipped),@"file":target};
}
