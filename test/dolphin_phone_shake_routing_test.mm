#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include "../packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShakeRouting.h"
#include "../packages/dolphin_internal_bridge/ios/Classes/DolphinPhoneShakeLabels.h"

static NSMutableDictionary* s_snapshot;
static NSMutableArray* s_requests;
static int s_failApply;
static const char* s_badJSON;
static int s_runtimeMarker;

extern "C" char* neostation_dolphin_menu_snapshot(int32_t wii, int32_t slot) {
  assert(dispatch_get_specific(&s_runtimeMarker) == &s_runtimeMarker);
  assert(wii == 1 && slot == 0);
  if (s_badJSON) return strdup(s_badJSON);
  if (!s_snapshot) return nullptr;
  NSData* data = [NSJSONSerialization dataWithJSONObject:s_snapshot options:0 error:nil];
  return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String);
}
extern "C" int32_t neostation_dolphin_menu_apply(const char* text) {
  assert(dispatch_get_specific(&s_runtimeMarker) == &s_runtimeMarker);
  NSDictionary* request = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  assert([request[@"kind"] isEqual:@"binding"] && [request[@"wii"] boolValue] && [request[@"slot"] intValue] == 0);
  assert(([@[@"Shake/X", @"Shake/Y", @"Shake/Z"] containsObject:request[@"id"]]));
  [s_requests addObject:request];
  if (s_failApply > 0 && --s_failApply == 0) return 0;
  for (NSMutableDictionary* control in s_snapshot[@"controls"])
    if ([control[@"id"] isEqual:request[@"id"]]) control[@"expression"] = request[@"expression"];
  return 1;
}
static void Profile(NSString* device, NSString* mapping) {
  s_requests = [NSMutableArray new];
  s_failApply = 0;
  s_badJSON = nullptr;
  NSMutableArray* controls = [NSMutableArray new];
  for (NSString* name in @[@"Shake/X", @"Shake/Y", @"Shake/Z"])
    [controls addObject:[@{@"id": name, @"expression": mapping} mutableCopy]];
  [controls addObject:[@{@"id": @"Buttons/A", @"expression": @"custom button untouched"} mutableCopy]];
  s_snapshot = [@{@"device": device, @"controls": controls,
    @"extensions": @[@{@"name": @"Nunchuk", @"selected": @YES}]} mutableCopy];
}
int main() { @autoreleasepool {
  dispatch_queue_t runtime = dispatch_queue_create("test.dolphin.runtime", DISPATCH_QUEUE_SERIAL);
  dispatch_queue_set_specific(runtime, &s_runtimeMarker, &s_runtimeMarker, nullptr);
  DOLPhoneShakeSetRuntimeQueue(runtime);
  // Touch/physical/custom/cleared expressions all gain an independent phone
  // branch. The production C ABI requests remain limited to these 3 controls.
  for (NSString* mapping in @[@"`Button 132`", @"`R Shoulder`", @"`L Trigger` & !`Button A`", @""]) {
    Profile([mapping isEqual:@"`Button 132`"] ? @"iOS/4/Touchscreen" : @"MFi/0/Gamepad", mapping);
    assert(DOLPreparePhoneShakeRouting());
    assert(DOLPhoneShakeRoutingStatus() == 1 && s_requests.count == 3);
    assert([s_snapshot[@"controls"][3][@"expression"] isEqual:@"custom button untouched"]);
    assert(DOLPreparePhoneShakeRouting() && s_requests.count == 3);
    for (int axis = 0; axis < 3; ++axis) {
      NSString* phone = [NSString stringWithFormat:@"`iOS/4/Touchscreen:Button %d`", 132 + axis];
      NSString* expected = mapping.length ? [NSString stringWithFormat:@"(%@) | %@", mapping, phone] : phone;
      assert([s_snapshot[@"controls"][axis][@"expression"] isEqual:expected]);
    }
  }
  // The first GC notification may still see Touch. The actual donor monitor
  // later publishes Physical without another GC event; reprepare preserves it.
  Profile(@"iOS/4/Touchscreen", @"`Button 132`");
  assert(DOLPreparePhoneShakeRouting());
  Profile(@"MFi/1/Reconnected", @"`R Trigger`");
  assert(DOLPreparePhoneShakeRouting());
  assert([s_snapshot[@"controls"][0][@"expression"] hasPrefix:@"(`R Trigger`)"]);
  Profile(@"iOS/4/Touchscreen", @"`Button 132`");
  assert(DOLPreparePhoneShakeRouting());
  // Classic is intentionally not a phone-motion controller.
  s_snapshot[@"extensions"] = @[@{@"name": @"Classic", @"selected": @YES}];
  NSUInteger before = s_requests.count;
  assert(!DOLPreparePhoneShakeRouting() && DOLPhoneShakeRoutingStatus() == 4 && s_requests.count == before);
  // Failed mapping must stay unavailable, and an explicit retry is idempotent.
  Profile(@"MFi/0/Gamepad", @"`R Shoulder`"); s_failApply = 2;
  assert(!DOLPreparePhoneShakeRouting() && DOLPhoneShakeRoutingStatus() == 2);
  s_failApply = 0;
  assert(DOLPreparePhoneShakeRouting() && s_requests.count == 4);
  s_snapshot = nil;
  assert(!DOLPreparePhoneShakeRouting() && DOLPhoneShakeRoutingStatus() == 2);
  s_badJSON = "broken";
  assert(!DOLPreparePhoneShakeRouting());
  Profile(@"MFi/0/Gamepad", @"`R Shoulder`");
  [s_snapshot[@"controls"] removeObjectAtIndex:0];
  assert(!DOLPreparePhoneShakeRouting());
  Profile(@"MFi/0/Gamepad", @"`R Shoulder`"); s_snapshot[@"extensions"] = NSNull.null;
  assert(!DOLPreparePhoneShakeRouting());
  Profile(@"MFi/0/Gamepad", @"`R Shoulder`"); s_snapshot[@"controls"] = @[NSNull.null];
  assert(!DOLPreparePhoneShakeRouting());
  DOLPhoneShakeSensorUnavailable(); assert(DOLPhoneShakeRoutingStatus() == 3);
  for (NSString* locale in @[@"en", @"es", @"ru", @"zh", @"zh_Hant", @"pt", @"fr", @"de", @"it", @"id", @"ja", @"ko"])
    for (NSString* key in @[@"title", @"help", @"usage", @"routeFailed", @"sensorUnavailable"])
      assert(![DOLPhoneShakeText(key, locale) isEqual:key]);
  for (NSString* locale in @[@"zh-Hant", @"zh_TW", @"zh-HK"])
    assert([DOLPhoneShakeText(@"routeFailed", locale) isEqual:DOLPhoneShakeText(@"routeFailed", @"zh_Hant")]);
  std::cout << "PASS: production routing shim, actual JSON C ABI requests, serialized profile/hotplug/failure/retry behavior\n";
} }
