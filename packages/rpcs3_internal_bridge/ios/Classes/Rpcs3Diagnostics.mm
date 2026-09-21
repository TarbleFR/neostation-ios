#import "Rpcs3Diagnostics.h"

#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>

static const unsigned long long kRPCS3DiagnosticLimit = 2 * 1024 * 1024;
static const unsigned long long kRPCS3MilestoneLimit = 512 * 1024;

@interface RPCS3DiagnosticsWriter : NSObject
- (void)writeDiagnosticStage:(nullable NSString*)stage
                      message:(nullable NSString*)message;
- (void)writeMilestoneStage:(nullable NSString*)stage
                     message:(nullable NSString*)message;
#if defined(RPCS3_DIAGNOSTICS_TESTING)
- (void)setDirectoryForTesting:(NSString*)directory;
- (void)flushForTesting;
#endif
@end

@implementation RPCS3DiagnosticsWriter {
  dispatch_queue_t _diagnosticQueue;
  NSObject* _milestoneLock;
  NSString* _diagnosticPath;
  NSString* _milestonePath;
  NSFileHandle* _diagnosticFile;
  unsigned long long _diagnosticLength;
#if defined(RPCS3_DIAGNOSTICS_TESTING)
  NSString* _testDirectory;
#endif
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _diagnosticQueue = dispatch_queue_create(
        "com.neogamelab.neostation.rpcs3.diagnostics",
        DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(
        _diagnosticQueue,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    _milestoneLock = [NSObject new];
  }
  return self;
}

- (NSString*)documentsDirectory {
#if defined(RPCS3_DIAGNOSTICS_TESTING)
  if (_testDirectory.length > 0) return _testDirectory;
#endif
  return NSSearchPathForDirectoriesInDomains(
      NSDocumentDirectory, NSUserDomainMask, YES).firstObject ?: @"";
}

- (NSString*)diagnosticPath {
  if (_diagnosticPath.length == 0) {
    NSString* directory = [self documentsDirectory];
    _diagnosticPath = directory.length > 0
        ? [directory stringByAppendingPathComponent:@"RPCS3-diagnostic.log"]
        : @"";
  }
  return _diagnosticPath;
}

- (NSString*)milestonePath {
  if (_milestonePath.length == 0) {
    NSString* directory = [self documentsDirectory];
    _milestonePath = directory.length > 0
        ? [directory stringByAppendingPathComponent:@"RPCS3-milestones.log"]
        : @"";
  }
  return _milestonePath;
}

- (void)closeDiagnosticFile {
  @try {
    [_diagnosticFile closeFile];
  } @catch (__unused NSException* exception) {
  }
  _diagnosticFile = nil;
  _diagnosticLength = 0;
}

- (BOOL)diagnosticFileStillOwnsPath:(NSString*)path {
  if (!_diagnosticFile || path.length == 0) return NO;
  struct stat descriptorInfo = {};
  struct stat pathInfo = {};
  if (fstat(_diagnosticFile.fileDescriptor, &descriptorInfo) != 0 ||
      stat(path.fileSystemRepresentation, &pathInfo) != 0) {
    return NO;
  }
  return descriptorInfo.st_dev == pathInfo.st_dev &&
      descriptorInfo.st_ino == pathInfo.st_ino;
}

- (BOOL)openDiagnosticFileAtPath:(NSString*)path {
  if (path.length == 0) return NO;
  if (_diagnosticFile && ![self diagnosticFileStillOwnsPath:path]) {
    [self closeDiagnosticFile];
  }
  if (_diagnosticFile) return YES;

  NSFileManager* files = NSFileManager.defaultManager;
  if (![files fileExistsAtPath:path] &&
      ![files createFileAtPath:path contents:nil attributes:nil]) {
    return NO;
  }
  _diagnosticFile = [NSFileHandle fileHandleForWritingAtPath:path];
  if (!_diagnosticFile) return NO;
  _diagnosticLength = [_diagnosticFile seekToEndOfFile];
  return YES;
}

- (NSData*)lineForStage:(nullable NSString*)stage
                message:(nullable NSString*)message
              timestamp:(NSTimeInterval)timestamp {
  NSDictionary* entry = @{
    @"pid": @(getpid()),
    @"build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"unknown",
    @"timestamp": @(timestamp),
    @"stage": stage ?: @"",
    @"message": message ?: @"",
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:entry
                                                 options:0
                                                   error:nil];
  if (!json) return nil;
  NSMutableData* line = [json mutableCopy];
  [line appendBytes:"\n" length:1];
  return line;
}

- (void)writeDiagnosticStage:(nullable NSString*)stage
                      message:(nullable NSString*)message {
  NSString* stageCopy = [stage copy] ?: @"";
  NSString* messageCopy = [message copy] ?: @"";
  NSTimeInterval timestamp = [NSDate.date timeIntervalSince1970];

  dispatch_async(_diagnosticQueue, ^{
    @autoreleasepool {
      @try {
        NSString* path = [self diagnosticPath];
        if (![self openDiagnosticFileAtPath:path]) return;
        NSData* line = [self lineForStage:stageCopy
                                 message:messageCopy
                               timestamp:timestamp];
        if (!line) return;
        if (self->_diagnosticLength + line.length > kRPCS3DiagnosticLimit) {
          [self->_diagnosticFile truncateFileAtOffset:0];
          [self->_diagnosticFile seekToFileOffset:0];
          self->_diagnosticLength = 0;
        }
        [self->_diagnosticFile writeData:line];
        self->_diagnosticLength += line.length;
      } @catch (__unused NSException* exception) {
        [self closeDiagnosticFile];
      }
    }
  });
}

- (void)writeMilestoneStage:(nullable NSString*)stage
                     message:(nullable NSString*)message {
  NSString* stageCopy = [stage copy] ?: @"";
  NSString* messageCopy = [message copy] ?: @"";
  NSTimeInterval timestamp = [NSDate.date timeIntervalSince1970];

  @synchronized(_milestoneLock) {
    @try {
      NSString* path = [self milestonePath];
      if (path.length == 0) return;
      NSFileManager* files = NSFileManager.defaultManager;
      if (![files fileExistsAtPath:path] &&
          ![files createFileAtPath:path contents:nil attributes:nil]) {
        return;
      }
      NSFileHandle* file = [NSFileHandle fileHandleForWritingAtPath:path];
      if (!file) return;
      unsigned long long length = [file seekToEndOfFile];
      NSData* line = [self lineForStage:stageCopy
                               message:messageCopy
                             timestamp:timestamp];
      if (line) {
        if (length + line.length > kRPCS3MilestoneLimit) {
          [file truncateFileAtOffset:0];
          [file seekToFileOffset:0];
        }
        [file writeData:line];
        // Milestones bound process-crash locations, so each entry is durable
        // before control crosses into debugger, dlopen, initialize or boot.
        [file synchronizeFile];
      }
      [file closeFile];
    } @catch (__unused NSException* exception) {
    }
  }
}

#if defined(RPCS3_DIAGNOSTICS_TESTING)
- (void)setDirectoryForTesting:(NSString*)directory {
  NSString* directoryCopy = [directory copy];
  dispatch_sync(_diagnosticQueue, ^{
    [self closeDiagnosticFile];
    self->_testDirectory = directoryCopy;
    self->_diagnosticPath = nil;
  });
  @synchronized(_milestoneLock) {
    _testDirectory = directoryCopy;
    _milestonePath = nil;
  }
}

- (void)flushForTesting {
  dispatch_sync(_diagnosticQueue, ^{
    @try {
      [self->_diagnosticFile synchronizeFile];
    } @catch (__unused NSException* exception) {
    }
  });
}
#endif

@end

static RPCS3DiagnosticsWriter* RPCS3SharedDiagnosticsWriter(void) {
  static RPCS3DiagnosticsWriter* writer;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    writer = [RPCS3DiagnosticsWriter new];
  });
  return writer;
}

void RPCS3Diagnostic(NSString* stage, NSString* message) {
  [RPCS3SharedDiagnosticsWriter() writeDiagnosticStage:stage message:message];
}

void RPCS3Milestone(NSString* stage, NSString* message) {
  [RPCS3SharedDiagnosticsWriter() writeMilestoneStage:stage message:message];
}

#if defined(RPCS3_DIAGNOSTICS_TESTING)
void RPCS3DiagnosticsSetDirectoryForTesting(NSString* directory) {
  [RPCS3SharedDiagnosticsWriter() setDirectoryForTesting:directory];
}

void RPCS3DiagnosticsFlushForTesting(void) {
  [RPCS3SharedDiagnosticsWriter() flushForTesting];
}
#endif
