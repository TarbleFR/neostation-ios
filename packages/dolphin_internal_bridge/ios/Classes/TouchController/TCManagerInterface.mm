// Adapted from DolphiniOS 7cac5416. SPDX-License-Identifier: GPL-2.0-or-later
#import "TCManagerInterface.h"
#include <stdint.h>
extern "C" void neostation_dolphin_touch_event(int32_t, int32_t, float, int32_t);

@implementation TCManagerInterface
+ (void)setButtonStateFor:(NSInteger)button controller:(NSInteger)controllerId state:(BOOL)state {
  neostation_dolphin_touch_event((int32_t)controllerId, (int32_t)button, state ? 1.0f : 0.0f, 0);
}
+ (void)setAxisValueFor:(NSInteger)axis controller:(NSInteger)controllerId value:(float)value {
  neostation_dolphin_touch_event((int32_t)controllerId, (int32_t)axis, value, 1);
}
@end
