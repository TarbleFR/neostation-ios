// SPDX-License-Identifier: MIT
#pragma once
#import <Foundation/Foundation.h>
#include "StorageABI.h"
#include "SourceABI.h"
#ifdef __cplusplus
extern "C" {
#endif
void NeoSwapStorage_Initialize(void);
const NeoSwapStorageAPI* NeoSwapStorage_GetAPI(uint32_t version);
const NeoSwapSourceAPI* NeoSwapStorage_GetSourceAPI(uint32_t version);
void NeoSwapStorage_SetBinderResult(int result);
// Global budget controller input: while set, cold video pixels are archived
// before the process headroom alone would require it. Admission still refuses
// under system pressure, in the background and with stale measurements.
void NeoSwapStorage_SetBudgetShrink(BOOL shrink);
void NeoSwapStorage_SetSourceBinderResult(int result);
void NeoSwapStorage_BeginSession(NSString* title);
void NeoSwapStorage_EndSession(void);
void NeoSwapStorage_SetPreference(BOOL enabled);
BOOL NeoSwapStorage_GetPreference(void);
NSDictionary* NeoSwapStorage_Diagnostics(void);
// Diagnostics worker only. Consumes at most 128 events, with explicit gap
// counters. No filesystem I/O, wait for the utility FIFO or Core getter call.
NSDictionary* NeoSwapStorage_DrainOperations(void);
#ifdef __cplusplus
}
#endif
