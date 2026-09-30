// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <stdint.h>
#include <dispatch/dispatch.h>

// Status: 0 not checked, 1 routed, 2 route failed, 3 sensor unavailable,
// 4 Classic Controller (phone shakes intentionally unavailable).
bool DOLPreparePhoneShakeRouting(void);
int32_t DOLPhoneShakeRoutingStatus(void);
void DOLPhoneShakeSensorUnavailable(void);
void DOLPhoneShakeSetRuntimeQueue(dispatch_queue_t queue);
