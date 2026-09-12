#pragma once

#import <Foundation/Foundation.h>

// Persist milestones before entering the Core: a native constructor crash
// cannot be caught by Dart, and asynchronous Flutter logging can lose it.
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  static NSObject* lock;
  static NSString* path;
  static NSFileHandle* file;
  static unsigned long long length = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSObject new];
    NSString* documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    path = [documents stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
  });
  @autoreleasepool {
  @synchronized(lock) {
    if (!path) return;
    @try {
      // Keep the Core's high-frequency log stream on one descriptor. Native
      // milestones close it below, so the next operation reopens the path.
      if (!file) {
        NSFileManager* files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
        file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file) return;
        length = [file seekToEndOfFile];
      }
      NSDictionary* entry = @{@"timestamp": @([NSDate.date timeIntervalSince1970]),
                               @"stage": stage ?: @"", @"message": message ?: @""};
      NSData* json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
      if (json) {
        NSMutableData* line = [json mutableCopy];
        [line appendBytes:"\n" length:1];
        if (length + line.length > 2 * 1024 * 1024) {
          [file truncateFileAtOffset:0];
          [file seekToFileOffset:0];
          length = 0;
        }
        [file writeData:line];
        length += line.length;
        // Compilation emits many module notices. A synchronous fsync for
        // every one stalls the compiler on storage; keep boot milestones
        // durable and let the OS buffer the ordinary Core log stream.
        if (![stage isEqualToString:@"core_log"]) {
          [file synchronizeFile];
          [file closeFile];
          file = nil;
        }
      }
    } @catch (__unused NSException* exception) {
      // Diagnostic I/O must never abort an import.
      @try { [file closeFile]; } @catch (__unused NSException* ignored) {}
      file = nil;
      length = 0;
    }
  }
  }
}
