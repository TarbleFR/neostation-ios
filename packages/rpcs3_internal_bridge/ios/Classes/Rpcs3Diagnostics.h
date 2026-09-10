#pragma once

#import <Foundation/Foundation.h>

// Persist milestones before entering the Core: a native constructor crash
// cannot be caught by Dart, and asynchronous Flutter logging can lose it.
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  static NSObject* lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ lock = [NSObject new]; });
  @synchronized(lock) {
    NSString* documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!documents) return;
    NSString* path = [documents stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
    NSFileManager* files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:path]) [files createFileAtPath:path contents:nil attributes:nil];
    NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) return;
    @try {
      unsigned long long length = [file seekToEndOfFile];
      if (length > 2 * 1024 * 1024) { [file truncateFileAtOffset:0]; [file seekToFileOffset:0]; }
      NSDictionary* entry = @{@"timestamp": @([NSDate.date timeIntervalSince1970]),
                               @"stage": stage ?: @"", @"message": message ?: @""};
      NSData* json = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
      if (json) {
        [file writeData:json];
        [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
        // Compilation emits many module notices. A synchronous fsync for
        // every one stalls the compiler on storage; keep boot milestones
        // durable and let the OS buffer the ordinary Core log stream.
        if (![stage isEqualToString:@"core_log"]) [file synchronizeFile];
      }
    } @catch (__unused NSException* exception) {
      // Diagnostic I/O must never abort an import.
    } @finally {
      [file closeFile];
    }
  }
}
