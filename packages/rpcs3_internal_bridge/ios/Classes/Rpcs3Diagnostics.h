#pragma once

#import <Foundation/Foundation.h>

// RPCS3 loader/game diagnostics must never synchronously fsync or block the
// JIT/Core hot path. Callers enqueue immutable records; one utility queue owns
// all file I/O.
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  static dispatch_queue_t queue;
  static NSString* path;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create(
        "com.neogamelab.neostation.rpcs3.diagnostics",
        DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(
        queue,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    NSString* documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    path = [documents stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
  });

  NSString* stageCopy = [stage copy] ?: @"";
  NSString* messageCopy = [message copy] ?: @"";
  NSTimeInterval timestamp = [NSDate.date timeIntervalSince1970];

  dispatch_async(queue, ^{
    @autoreleasepool {
      if (!path) return;
      @try {
        NSFileManager* files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:path]) {
          [files createFileAtPath:path contents:nil attributes:nil];
        }

        NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file) return;
        unsigned long long length = [file seekToEndOfFile];

        NSDictionary* entry = @{
          @"timestamp": @(timestamp),
          @"stage": stageCopy,
          @"message": messageCopy,
        };
        NSData* json = [NSJSONSerialization dataWithJSONObject:entry
                                                       options:0
                                                         error:nil];
        if (json) {
          NSMutableData* line = [json mutableCopy];
          [line appendBytes:"\n" length:1];
          if (length + line.length > 2 * 1024 * 1024) {
            [file truncateFileAtOffset:0];
            [file seekToFileOffset:0];
          }
          [file writeData:line];
        }
        [file closeFile];
      } @catch (__unused NSException* exception) {
      }
    }
  });
}
