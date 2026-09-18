#pragma once

#import <Foundation/Foundation.h>

// Ordinary diagnostics are asynchronous and use one persistent descriptor.
// High-frequency Core messages are filtered/rate-limited by RPCS3Log before
// they reach this function.
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  static dispatch_queue_t queue;
  static NSString* path;
  static NSFileHandle* file;
  static unsigned long long length = 0;
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
        if (!file) {
          NSFileManager* files = NSFileManager.defaultManager;
          if (![files fileExistsAtPath:path]) {
            [files createFileAtPath:path contents:nil attributes:nil];
          }
          file = [NSFileHandle fileHandleForWritingAtPath:path];
          if (!file) return;
          length = [file seekToEndOfFile];
        }

        NSDictionary* entry = @{
          @"timestamp": @(timestamp),
          @"stage": stageCopy,
          @"message": messageCopy,
        };
        NSData* json = [NSJSONSerialization dataWithJSONObject:entry
                                                       options:0
                                                         error:nil];
        if (!json) return;

        NSMutableData* line = [json mutableCopy];
        [line appendBytes:"\n" length:1];
        if (length + line.length > 2 * 1024 * 1024) {
          [file truncateFileAtOffset:0];
          [file seekToFileOffset:0];
          length = 0;
        }
        [file writeData:line];
        length += line.length;
      } @catch (__unused NSException* exception) {
        @try { [file closeFile]; } @catch (__unused NSException* ignored) {}
        file = nil;
        length = 0;
      }
    }
  });
}

// Crash-boundary milestones are deliberately separate from the noisy Core log.
// There are only a few per boot, so a synchronous flush is acceptable and
// guarantees that a process dying inside dlopen/initialize/boot leaves a
// durable last-known stage.
static inline void RPCS3Milestone(NSString* stage, NSString* message) {
  static NSObject* lock;
  static NSString* path;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [NSObject new];
    NSString* documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    path = [documents stringByAppendingPathComponent:@"RPCS3-milestones.log"];
  });

  @synchronized(lock) {
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
        @"timestamp": @([NSDate.date timeIntervalSince1970]),
        @"stage": stage ?: @"",
        @"message": message ?: @"",
      };
      NSData* json = [NSJSONSerialization dataWithJSONObject:entry
                                                     options:0
                                                       error:nil];
      if (json) {
        NSMutableData* line = [json mutableCopy];
        [line appendBytes:"\n" length:1];
        if (length + line.length > 512 * 1024) {
          [file truncateFileAtOffset:0];
          [file seekToFileOffset:0];
        }
        [file writeData:line];
        [file synchronizeFile];
      }
      [file closeFile];
    } @catch (__unused NSException* exception) {
    }
  }
}
