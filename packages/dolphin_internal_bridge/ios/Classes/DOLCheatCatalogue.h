// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <Foundation/Foundation.h>
#include "NeoCheatStore.h"

// Exact identity only. PAL/NTSC and different revisions are never guessed.
static void DOLFetchCheatCatalogues(NSDictionary* identity,void (^completion)(NSDictionary*)) {
  NSString* gameId=NeoField(identity,@"gameId");
  NSString* tdb=NeoField(identity,@"gameTdbId");
  if(!NeoRegex(gameId,@"^[A-Z0-9]{6}$") || ![identity[@"revision"] isKindOfClass:NSNumber.class]) {
    completion(NeoCheatFailure(@"wrongGame"));return;
  }
  NSMutableArray<NSDictionary*>* sources=[NSMutableArray array];
  if(NeoRegex(tdb,@"^[A-Z0-9]{4}([A-Z0-9]{2})?$"))
    [sources addObject:@{@"kind":@"gecko",@"id":tdb,@"url":[@"https://codes.rc24.xyz/txt.php?txt=" stringByAppendingString:tdb]}];
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
