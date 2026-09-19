#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

// Ordinary diagnostics are serialized by one process-wide writer implemented
// in Rpcs3Diagnostics.mm. Keeping the implementation out of this header is
// essential: both the JIT bridge and the Core bridge write the same files.
FOUNDATION_EXPORT void RPCS3Diagnostic(
    NSString* _Nullable stage,
    NSString* _Nullable message);

// Crash-boundary milestones are synchronously persisted by that same writer.
FOUNDATION_EXPORT void RPCS3Milestone(
    NSString* _Nullable stage,
    NSString* _Nullable message);

#if defined(RPCS3_DIAGNOSTICS_TESTING)
// Native regression tests redirect Documents and explicitly drain the
// asynchronous diagnostic queue. These symbols are absent from production.
FOUNDATION_EXPORT void RPCS3DiagnosticsSetDirectoryForTesting(
    NSString* directory);
FOUNDATION_EXPORT void RPCS3DiagnosticsFlushForTesting(void);
#endif

#ifdef __cplusplus
}  // extern "C"
#endif

NS_ASSUME_NONNULL_END
