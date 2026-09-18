#import <Foundation/Foundation.h>
#include <cassert>
#include <cstring>
static NSString* testDocuments;
#define NSSearchPathForDirectoriesInDomains(...) (@[testDocuments])
#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"
#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3EarlyLoaderDiagnostics.h"
#undef NSSearchPathForDirectoriesInDomains
int main(int argc, const char* argv[]) {
  @autoreleasepool {
    assert(argc == 3);
    testDocuments = [NSString stringWithUTF8String:argv[1]];
    if (strcmp(argv[2], "crash") == 0) {
      RPCS3EarlyLoaderCapture capture;
      const char marker[] = "SIMULATED_CONSTRUCTOR_FAILURE_270\n";
      (void)write(STDERR_FILENO, marker, sizeof(marker) - 1);
      (void)fsync(STDERR_FILENO);
      _exit(23); // Abrupt exit, no C++ destructor, not a real device crash.
    }
    RPCS3RecoverEarlyLoaderLog();
    NSString* log = [testDocuments stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
    NSString* contents = nil;
    for (int attempt = 0; attempt < 100; ++attempt) {
      contents = [NSString stringWithContentsOfFile:log
                                          encoding:NSUTF8StringEncoding
                                             error:nil];
      if ([contents containsString:@"SIMULATED_CONSTRUCTOR_FAILURE_270"]) break;
      usleep(10 * 1000);
    }
    assert([contents containsString:@"SIMULATED_CONSTRUCTOR_FAILURE_270"]);
    assert(![NSFileManager.defaultManager fileExistsAtPath:RPCS3EarlyLoaderPath()]);
    {
      RPCS3EarlyLoaderCapture capture;
      fprintf(stderr, "SUCCESSFUL_LOAD_CAPTURE_270\n");
    }
    fprintf(stderr, "RESTORED_STDERR_270\n");
    contents = [NSString stringWithContentsOfFile:log encoding:NSUTF8StringEncoding error:nil];
    assert([contents containsString:@"SUCCESSFUL_LOAD_CAPTURE_270"]);
    assert(![contents containsString:@"RESTORED_STDERR_270"]);
    printf("PASS: build270 native early-loader failure recovery and stderr restoration\n");
  }
}
