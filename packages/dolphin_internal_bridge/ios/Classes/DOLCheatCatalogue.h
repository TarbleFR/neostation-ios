// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "NeoCheatStore.h"

// Curated source adapter: only this exact PAL GameID maps to this author topic.
// No code bytes are bundled. Fetch is user-initiated; keep authors/source links.
static NeoCheat::Result DOLForumGecko(NSString* html,NSString* gameId) {
  NeoCheat::Result result;
  if(![gameId isEqual:@"G4BP08"] || ![html containsString:@"[G4BP08]"] ||
      ![html containsString:@"GCN/WIIRD/PAL"]){result.error="identity";return result;}
  NSRange opening=[html rangeOfString:@"<code>"];
  if(opening.location==NSNotFound){result.error="format";return result;}
  NSRange closing=[html rangeOfString:@"</code>" options:0 range:NSMakeRange(NSMaxRange(opening),html.length-NSMaxRange(opening))];
  if(closing.location==NSNotFound){result.error="format";return result;}
  NSString* body=[html substringWithRange:NSMakeRange(NSMaxRange(opening),closing.location-NSMaxRange(opening))];
  body=[body stringByReplacingOccurrencesOfString:@"<br\\s*/?>" withString:@"\n" options:NSRegularExpressionSearch range:NSMakeRange(0,body.length)];
  for(NSArray* entity in @[@[@"&amp;",@"&"],@[@"&quot;",@"\""],@[@"&#039;",@"'"],@[@"&#39;",@"'"],@[@"&lt;",@"<"],@[@"&gt;",@">"],@[@"&nbsp;",@" "]])body=[body stringByReplacingOccurrencesOfString:entity[0] withString:entity[1]];
  std::istringstream lines(NeoCheat::normalizeText(body.UTF8String));std::string line;
  NeoCheat::Entry entry;entry.type="gecko";bool invalid=false;
  auto finish=[&]{
    if(!entry.lines.empty() && !invalid) {
      entry.notes.push_back("Source: https://www.gc-forever.com/forums/viewtopic.php?t=2145");
      entry.notes.push_back("GameID G4BP08 (PAL). The author does not specify a disc revision. Enable only after checking compatibility.");
      result.entries.push_back(entry);
    }
    entry=NeoCheat::Entry{};entry.type="gecko";invalid=false;
  };
  while(std::getline(lines,line)) {
    line=NeoCheat::trim(line);if(line.empty())continue;
    const auto credit=line.rfind('[');
    if(credit!=std::string::npos && line.back()==']') {
      finish();entry.name=NeoCheat::trim(line.substr(0,credit));entry.creator=line.substr(credit+1,line.size()-credit-2);
      if(!NeoCheat::safeName(entry.name)||!NeoCheat::safeName(entry.creator))invalid=true;
      continue;
    }
    if(entry.name.empty())continue;
    std::string normalized;
    if(NeoCheat::rawLine(line,&normalized))entry.lines.push_back(normalized);
    else {
      // Never import a valid prefix of a code containing unresolved variables.
      std::istringstream fields(line);std::string first,second;fields>>first>>second;
      if(first.size()==8 && second.size()==8)invalid=true;
      entry.notes.push_back(line);
    }
    if(entry.lines.size()>8192){result.error="size";return result;}
  }
  finish();return result;
}

// Exact GameID/region only. Source revision uncertainty is explicitly retained.
static void DOLFetchCheatCatalogues(NSDictionary* identity,void (^completion)(NSDictionary*)) {
  NSString* gameId=NeoField(identity,@"gameId");
  NSString* tdb=NeoField(identity,@"gameTdbId");
  if(!NeoRegex(gameId,@"^[A-Z0-9]{6}$") || ![identity[@"revision"] isKindOfClass:NSNumber.class]) {
    completion(NeoCheatFailure(@"wrongGame"));return;
  }
  NSMutableArray<NSDictionary*>* sources=[NSMutableArray array];
  if(NeoRegex(tdb,@"^[A-Z0-9]{4}([A-Z0-9]{2})?$"))
    [sources addObject:@{@"kind":@"gecko",@"id":tdb,@"url":[@"https://codes.rc24.xyz/txt.php?txt=" stringByAppendingString:tdb]}];
  if([gameId isEqual:@"G4BP08"]) [sources addObject:@{@"kind":@"forum",@"id":gameId,@"url":@"https://www.gc-forever.com/forums/viewtopic.php?t=2145"}];
  NSString* base=@"https://raw.githubusercontent.com/dolphin-emu/dolphin/master/Data/Sys/GameSettings/";
  for(NSString* file in @[[NSString stringWithFormat:@"%@r%@.ini",gameId,identity[@"revision"]],[gameId stringByAppendingString:@".ini"]])
    [sources addObject:@{@"kind":@"ini",@"url":[base stringByAppendingString:file]}];
  NSURLSessionConfiguration* config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
  config.timeoutIntervalForRequest=10;config.timeoutIntervalForResource=15;
  config.HTTPAdditionalHeaders=@{@"User-Agent":@"NeoStation-CheatCatalogue/1.0"};
  NSURLSession* session=[NSURLSession sessionWithConfiguration:config];
  dispatch_group_t group=dispatch_group_create();
  NSMutableArray* responses=[NSMutableArray array];
  for(NSDictionary* source in sources) {
    dispatch_group_enter(group);
    [[session dataTaskWithURL:[NSURL URLWithString:source[@"url"]] completionHandler:^(NSData* data,NSURLResponse* response,NSError* error){
      @autoreleasepool {
        NSInteger status=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse*)response statusCode]:0;
        NSDictionary* result;
        if(status==404 || status==410) result=@{@"missing":@YES};
        else if(error || status!=200) result=@{@"errorKey":@"networkError"};
        else {
          NSString* text=data.length<=1048576?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
          if(!text) result=@{@"errorKey":@"invalidResponse"};
          else {
            NeoCheat::Result parsed;
            if([source[@"kind"] isEqual:@"gecko"]) parsed=NeoCheat::geckoDownload(text.UTF8String,[source[@"id"] UTF8String]);
            else if([source[@"kind"] isEqual:@"forum"]) parsed=DOLForumGecko(text,source[@"id"]);
            else parsed=NeoCheat::parse(text.UTF8String,"ini","Catalogue");
            if(!parsed.error.empty() && parsed.error!="empty") result=@{@"errorKey":@"invalidResponse"};
            else result=@{@"content":NeoEntriesINI(parsed.entries),@"count":@(parsed.entries.size()),@"source":source[@"url"]};
          }
        }
        @synchronized(responses) {[responses addObject:result];}
        dispatch_group_leave(group);
      }
    }] resume];
  }
  dispatch_group_notify(group,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
    [session finishTasksAndInvalidate];
    NSMutableString* content=[NSMutableString string];NSMutableArray* provenance=[NSMutableArray array];
    NSString* problem=nil;NSUInteger count=0;
    for(NSDictionary* response in responses) {
      if(response[@"errorKey"])problem=response[@"errorKey"];
      if([response[@"count"] unsignedIntegerValue]) {
        [content appendString:response[@"content"]];count+=[response[@"count"] unsignedIntegerValue];[provenance addObject:response[@"source"]];
      }
    }
    if(!count) {completion(NeoCheatFailure(problem?:@"notFound"));return;}
    completion(@{@"success":@YES,@"content":content,@"downloaded":@(count),@"sources":provenance,@"partial":@(problem!=nil)});
  });
}
