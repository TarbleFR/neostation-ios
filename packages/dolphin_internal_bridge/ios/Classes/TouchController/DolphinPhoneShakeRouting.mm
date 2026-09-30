// SPDX-License-Identifier: GPL-3.0-or-later
#import <Foundation/Foundation.h>
#include <atomic>
#include <cstdlib>
#include <cstring>
#include "DolphinPhoneShakeBinding.h"
#include "DolphinPhoneShakeRouting.h"

extern "C" char* neostation_dolphin_menu_snapshot(int32_t, int32_t);
extern "C" int32_t neostation_dolphin_menu_apply(const char*);

static std::atomic<int32_t> s_phoneShakeRouteStatus{0};
static dispatch_queue_t s_phoneShakeRuntimeQueue;
void DOLPhoneShakeSetRuntimeQueue(dispatch_queue_t queue) { s_phoneShakeRuntimeQueue = queue; }
int32_t DOLPhoneShakeRoutingStatus(void) { return s_phoneShakeRouteStatus.load(); }
void DOLPhoneShakeSensorUnavailable(void) { s_phoneShakeRouteStatus.store(3); }

static bool DOLPhoneShakeRouteFailed(void) {
  s_phoneShakeRouteStatus.store(2);
  NSLog(@"[Dolphin PhoneShake] First Wii Remote shake input routing failed.");
  return false;
}

static bool DOLPreparePhoneShakeRoutingOnRuntime(void) {
  @autoreleasepool {
    // This executes on the emulator runtime worker. Donor APIs serialize with
    // Dolphin's host/CPU input locks; this path never accesses UIKit.
    char* text = neostation_dolphin_menu_snapshot(1, 0);
    if (!text) return DOLPhoneShakeRouteFailed();
    NSData* data = [NSData dataWithBytes:text length:std::strlen(text)];
    std::free(text);
    id decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![decoded isKindOfClass:NSDictionary.class]) return DOLPhoneShakeRouteFailed();
    NSDictionary* snapshot = decoded;
    if (![snapshot[@"extensions"] isKindOfClass:NSArray.class]) return DOLPhoneShakeRouteFailed();
    for (NSDictionary* extension in snapshot[@"extensions"]) {
      if (![extension isKindOfClass:NSDictionary.class]) return DOLPhoneShakeRouteFailed();
      if ([extension[@"selected"] boolValue] && [extension[@"name"] isEqual:@"Classic"]) {
        s_phoneShakeRouteStatus.store(4);
        return false;
      }
    }
    if (![snapshot[@"controls"] isKindOfClass:NSArray.class]) return DOLPhoneShakeRouteFailed();
    for (int axis = 0; axis < 3; ++axis) {
      NSString* identifier = @[@"Shake/X", @"Shake/Y", @"Shake/Z"][axis];
      NSDictionary* found = nil;
      for (NSDictionary* control in snapshot[@"controls"]) {
        if (![control isKindOfClass:NSDictionary.class]) return DOLPhoneShakeRouteFailed();
        if ([control[@"id"] isEqual:identifier]) { found = control; break; }
      }
      if (![found[@"expression"] isKindOfClass:NSString.class]) return DOLPhoneShakeRouteFailed();
      NSString* current = found[@"expression"];
      const std::string expression = DolphinPhoneShakeBinding::Augment(current.UTF8String, 132 + axis);
      if (expression == current.UTF8String) continue;
      NSDictionary* request = @{@"kind": @"binding", @"wii": @YES, @"slot": @0,
        @"id": identifier, @"expression": [NSString stringWithUTF8String:expression.c_str()]};
      NSData* requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
      if (!requestData) return DOLPhoneShakeRouteFailed();
      NSString* json = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
      if (neostation_dolphin_menu_apply(json.UTF8String) == 0) return DOLPhoneShakeRouteFailed();
    }
    s_phoneShakeRouteStatus.store(1);
    return true;
  }
}

bool DOLPreparePhoneShakeRouting(void) {
  if (!s_phoneShakeRuntimeQueue) return DOLPhoneShakeRouteFailed();
  __block bool ready = false;
  dispatch_sync(s_phoneShakeRuntimeQueue, ^{ ready = DOLPreparePhoneShakeRoutingOnRuntime(); });
  return ready;
}
