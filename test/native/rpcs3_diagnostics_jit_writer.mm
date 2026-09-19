#import <Foundation/Foundation.h>

#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"

extern "C" void RPCS3TestWriteJitDiagnostics(NSUInteger diagnosticCount,
                                               NSUInteger milestoneCount) {
  for (NSUInteger index = 0; index < diagnosticCount; ++index) {
    RPCS3Diagnostic(
        @"jit_test",
        [NSString stringWithFormat:@"jit-diagnostic-%lu", (unsigned long)index]);
  }
  for (NSUInteger index = 0; index < milestoneCount; ++index) {
    RPCS3Milestone(
        @"jit_milestone_test",
        [NSString stringWithFormat:@"jit-milestone-%lu", (unsigned long)index]);
  }
}
