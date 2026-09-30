#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// Host-owned preparation. No constructors are added to any emulator Core.
// Start is asynchronous. WaitReady never blocks the UI thread and never
// changes the normal allocation fallback when preparation is unavailable.
__attribute__((visibility("default"))) void NeoSwapRelay_Start(void);
// Schedules bounded cleanup and preparation retries on the host worker.
__attribute__((visibility("default"))) void NeoSwapRelay_Maintain(void);
__attribute__((visibility("default"))) int NeoSwapRelay_WaitReady(uint32_t timeout_ms);
#ifdef __cplusplus
}
#endif
#ifdef __OBJC__
@class NSDictionary;
NSDictionary* NeoSwapRelay_Diagnostics(void);
#endif
