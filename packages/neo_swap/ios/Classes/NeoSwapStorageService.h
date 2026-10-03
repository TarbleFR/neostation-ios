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
