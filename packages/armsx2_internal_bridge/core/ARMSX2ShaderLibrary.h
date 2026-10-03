// SPDX-License-Identifier: GPL-3.0-or-later
// Container-independent preset identities. Shared unchanged with Foundation tests.
#pragma once
#import <Foundation/Foundation.h>

static NSString* NeoShaderResolve(NSString* token, NSString* bundled, NSString* user) {
  if (![token isKindOfClass:NSString.class]) return nil;
  NSRange separator = [token rangeOfString:@":"];
  if (separator.location == NSNotFound) return nil;
  NSString* marker = [token substringToIndex:separator.location];
  NSString* relative = [token substringFromIndex:separator.location + 1];
  NSString* root = [marker isEqual:@"bundle"] ? bundled : ([marker isEqual:@"data"] ? user : nil);
  if (!root.length || !relative.length || relative.isAbsolutePath ||
      [relative.pathComponents containsObject:@".."] ||
      ![relative.pathExtension.lowercaseString isEqual:@"slangp"]) return nil;
  root = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* path = [root stringByAppendingPathComponent:relative].stringByStandardizingPath.stringByResolvingSymlinksInPath;
  BOOL directory = NO;
  if (![path hasPrefix:[root stringByAppendingString:@"/"]] ||
      ![NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] || directory) return nil;
  return path;
}

static NSArray<NSDictionary*>* NeoShaderScan(NSString* root, NSString* marker) {
  if (!root.length) return @[];
  root = root.stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSMutableArray* presets = [NSMutableArray array];
  NSDirectoryEnumerator* files = [NSFileManager.defaultManager enumeratorAtURL:
      [NSURL fileURLWithPath:root isDirectory:YES]
      includingPropertiesForKeys:@[NSURLIsSymbolicLinkKey, NSURLIsDirectoryKey]
      options:NSDirectoryEnumerationSkipsHiddenFiles errorHandler:nil];
  NSUInteger inspected = 0;
  for (NSURL* file in files) {
    if (++inspected > 32768) break;
    NSNumber* symbolic = nil;
    [file getResourceValue:&symbolic forKey:NSURLIsSymbolicLinkKey error:nil];
    if (symbolic.boolValue || files.level > 12) { [files skipDescendants]; continue; }
    if (![file.pathExtension.lowercaseString isEqual:@"slangp"]) continue;
    // NSURL enumeration can expand /var to /private/var. Derive relative
    // identities only after both sides have the same filesystem spelling.
    NSString* path=file.path.stringByStandardizingPath.stringByResolvingSymlinksInPath;
    if (![path hasPrefix:[root stringByAppendingString:@"/"]]) continue;
    NSString* relative = [path substringFromIndex:root.length + 1];
    NSString* token = [NSString stringWithFormat:@"%@:%@", marker, relative];
    if (!NeoShaderResolve(token, [marker isEqual:@"bundle"] ? root : nil,
                                [marker isEqual:@"data"] ? root : nil)) continue;
    [presets addObject:@{@"id":token, @"name":relative.stringByDeletingPathExtension}];
  }
  return [presets sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [a[@"name"] localizedStandardCompare:b[@"name"]];
  }];
}
