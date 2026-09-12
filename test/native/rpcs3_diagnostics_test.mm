#import <Foundation/Foundation.h>
#include <cassert>

static NSString* testDocuments;
// Compile the production implementation unchanged, but never write to the
// developer/runner's Documents directory.
#define NSSearchPathForDirectoriesInDomains(...) (@[testDocuments])
#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"
#undef NSSearchPathForDirectoriesInDomains

static NSArray<NSDictionary*>* readEntries(NSString* path) {
  NSString* data = [NSString stringWithContentsOfFile:path
      encoding:NSUTF8StringEncoding error:nil];
  assert(data != nil);
  assert([data hasSuffix:@"\n"]);
  NSMutableArray* entries = [NSMutableArray new];
  for (NSString* line in [data componentsSeparatedByString:@"\n"]) {
    if (line.length == 0) continue;
    NSDictionary* entry = [NSJSONSerialization JSONObjectWithData:
        [line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    assert([entry isKindOfClass:NSDictionary.class]);
    assert(entry[@"timestamp"] != nil);
    [entries addObject:entry];
  }
  return entries;
}

int main(int argc, const char* argv[]) {
  @autoreleasepool {
    assert(argc == 2);
    testDocuments = [NSString stringWithUTF8String:argv[1]];
    NSString* path = [testDocuments stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
    RPCS3Diagnostic(@"boot", @"start");
    dispatch_apply(1000, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^(size_t i) {
      RPCS3Diagnostic(@"core_log", [NSString stringWithFormat:@"line-%zu", i]);
    });
    // Writes must already be readable before any milestone flush/close.
    NSArray* entries = readEntries(path);
    assert(entries.count == 1001);
    NSMutableSet* messages = [NSMutableSet new];
    for (NSDictionary* entry in entries) [messages addObject:entry[@"message"]];
    assert(messages.count == 1001);
    RPCS3Diagnostic(@"stopped", @"durable");
    assert(readEntries(path).count == 1002);

    // A milestone releases the descriptor. The next stream must reopen the
    // actual path after an export/rotation of the previous file.
    assert([NSFileManager.defaultManager moveItemAtPath:path
        toPath:[path stringByAppendingString:@".previous"] error:nil]);
    RPCS3Diagnostic(@"core_log", @"reopened");
    assert(readEntries(path).count == 1);

    NSString* large = [@"x" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
    for (int i = 0; i < 700; ++i) RPCS3Diagnostic(@"core_log", large);
    RPCS3Diagnostic(@"stopped", @"after rotation");
    unsigned long long size = [[NSFileManager.defaultManager
        attributesOfItemAtPath:path error:nil] fileSize];
    assert(size <= 2 * 1024 * 1024);
    entries = readEntries(path);
    assert(entries.count > 1 && entries.count < 700);
    assert([entries.lastObject[@"message"] isEqualToString:@"after rotation"]);
    RPCS3Diagnostic(nil, nil);
    assert([readEntries(path).lastObject[@"stage"] isEqualToString:@""]);
  }
  return 0;
}
