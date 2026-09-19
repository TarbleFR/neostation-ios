#import <Foundation/Foundation.h>

#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"

extern "C" void RPCS3TestWriteCoreDiagnostics(NSUInteger diagnosticCount,
                                                NSUInteger milestoneCount) {
  for (NSUInteger index = 0; index < diagnosticCount; ++index) {
    RPCS3Diagnostic(
        @"core_test",
        [NSString stringWithFormat:@"core-diagnostic-%lu", (unsigned long)index]);
  }
  for (NSUInteger index = 0; index < milestoneCount; ++index) {
    RPCS3Milestone(
        @"core_milestone_test",
        [NSString stringWithFormat:@"core-milestone-%lu", (unsigned long)index]);
  }
}
