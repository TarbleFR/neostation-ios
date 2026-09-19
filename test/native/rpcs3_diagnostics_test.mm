#import <Foundation/Foundation.h>
#include <cassert>

#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"

extern "C" void RPCS3TestWriteCoreDiagnostics(NSUInteger diagnosticCount,
                                                NSUInteger milestoneCount);
extern "C" void RPCS3TestWriteJitDiagnostics(NSUInteger diagnosticCount,
                                               NSUInteger milestoneCount);

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
    NSString* testDocuments = [NSString stringWithUTF8String:argv[1]];
    RPCS3DiagnosticsSetDirectoryForTesting(testDocuments);
    NSString* path = [testDocuments stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
    NSString* milestonePath = [testDocuments
        stringByAppendingPathComponent:@"RPCS3-milestones.log"];

    // Calls originate from two independently compiled translation units. The
    // old static-inline implementation gave each one a different queue, file
    // descriptor, length counter and milestone lock for these same paths.
    dispatch_group_t producers = dispatch_group_create();
    dispatch_queue_t concurrent = dispatch_get_global_queue(
        QOS_CLASS_USER_INITIATED, 0);
    dispatch_group_async(producers, concurrent, ^{
      RPCS3TestWriteCoreDiagnostics(1000, 64);
    });
    dispatch_group_async(producers, concurrent, ^{
      RPCS3TestWriteJitDiagnostics(1000, 64);
    });
    assert(dispatch_group_wait(
        producers, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) == 0);
    RPCS3DiagnosticsFlushForTesting();

    NSArray* entries = readEntries(path);
    assert(entries.count == 2000);
    NSMutableSet* messages = [NSMutableSet new];
    for (NSDictionary* entry in entries) [messages addObject:entry[@"message"]];
    assert(messages.count == 2000);

    NSArray* milestones = readEntries(milestonePath);
    assert(milestones.count == 128);
    [messages removeAllObjects];
    for (NSDictionary* entry in milestones) [messages addObject:entry[@"message"]];
    assert(messages.count == 128);

    // An external export can move the path while the process retains its file
    // descriptor. The next write must detect that and reopen the real path.
    assert([NSFileManager.defaultManager moveItemAtPath:path
        toPath:[path stringByAppendingString:@".previous"] error:nil]);
    RPCS3Diagnostic(@"core_log", @"reopened");
    RPCS3DiagnosticsFlushForTesting();
    assert(readEntries(path).count == 1);

    NSString* large = [@"x" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
    for (int i = 0; i < 700; ++i) RPCS3Diagnostic(@"core_log", large);
    RPCS3Diagnostic(@"stopped", @"after rotation");
    RPCS3DiagnosticsFlushForTesting();
    unsigned long long size = [[NSFileManager.defaultManager
        attributesOfItemAtPath:path error:nil] fileSize];
    assert(size <= 2 * 1024 * 1024);
    entries = readEntries(path);
    assert(entries.count > 1 && entries.count < 700);
    assert([entries.lastObject[@"message"] isEqualToString:@"after rotation"]);
    RPCS3Diagnostic(nil, nil);
    RPCS3DiagnosticsFlushForTesting();
    assert([readEntries(path).lastObject[@"stage"] isEqualToString:@""]);
  }
  return 0;
}
