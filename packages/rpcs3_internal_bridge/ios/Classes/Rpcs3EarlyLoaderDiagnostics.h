#pragma once
// CocoaPods also imports public headers from Objective-C and Swift. The RAII
// capture is implementation-only C++ and must not leak into those importers.
#ifdef __cplusplus
#import <Foundation/Foundation.h>
#import "Rpcs3Diagnostics.h"
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>

// Do not install signal handlers or turn a failed constructor into success.
// Capture directly to disk: a pipe serviced by the stopped host can deadlock.
static inline NSString* RPCS3EarlyLoaderPath() {
  NSString* documents = NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [documents stringByAppendingPathComponent:@"RPCS3-core-load-stderr.log"];
}

static inline void RPCS3RecoverEarlyLoaderLog() {
  @try {
    NSString* path = RPCS3EarlyLoaderPath();
    NSFileHandle* file = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!file) return;
    unsigned long long size = [file seekToEndOfFile];
    [file seekToFileOffset:size > 65536 ? size - 65536 : 0];
    NSData* bytes = [file readDataToEndOfFile];
    [file closeFile];
    if (bytes.length) {
      NSString* text = [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding];
      if (!text) text = [[NSString alloc] initWithData:bytes encoding:NSISOLatin1StringEncoding];
      RPCS3Diagnostic(@"early_loader_stderr", text ?: @"Unreadable early loader diagnostic");
      [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    }
  } @catch (__unused NSException* exception) {}
}

class RPCS3EarlyLoaderCapture {
  int saved_ = -1;
public:
  RPCS3EarlyLoaderCapture() {
    // Recover the previous attempt before replacing its file. No user caches,
    // pairing data or game saves are touched by this bounded diagnostic.
    RPCS3RecoverEarlyLoaderLog();
    NSString* path = RPCS3EarlyLoaderPath();
    if (!path) return;
    int output = open(path.fileSystemRepresentation, O_CREAT | O_TRUNC | O_WRONLY | O_CLOEXEC, 0600);
    if (output < 0) return;
    fflush(stderr);
    saved_ = dup(STDERR_FILENO);
    if (saved_ >= 0 && dup2(output, STDERR_FILENO) < 0) {
      close(saved_);
      saved_ = -1;
    }
    close(output);
    if (saved_ >= 0) {
      static const char marker[] = "NEOSTATION_EARLY_LOADER_270: entering RPCS3 dlopen\n";
      (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
      (void)fsync(STDERR_FILENO);
    }
  }
  RPCS3EarlyLoaderCapture(const RPCS3EarlyLoaderCapture&) = delete;
  RPCS3EarlyLoaderCapture& operator=(const RPCS3EarlyLoaderCapture&) = delete;
  ~RPCS3EarlyLoaderCapture() {
    if (saved_ >= 0) {
      fflush(stderr);
      (void)fsync(STDERR_FILENO);
      (void)dup2(saved_, STDERR_FILENO);
      close(saved_);
      RPCS3RecoverEarlyLoaderLog();
    }
  }
};
#endif // __cplusplus
