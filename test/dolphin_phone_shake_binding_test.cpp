#include <cassert>
#include <iostream>
#include "../packages/dolphin_internal_bridge/ios/Classes/TouchController/DolphinPhoneShakeBinding.h"

int main() {
  using DolphinPhoneShakeBinding::Augment;
  for (int button = 132; button <= 134; ++button) {
    const std::string phone = "`iOS/4/Touchscreen:Button " + std::to_string(button) + "`";
    assert(Augment("", button) == phone);
    assert(Augment(" \t\n", button) == phone);
    for (const auto& mapping : {"`R Shoulder`", "`L Trigger` & !`Button A`", "if(`Button A`, 1, 0)", "`Button 132`"}) {
      const auto augmented = Augment(mapping, button);
      assert(augmented == "(" + std::string(mapping) + ") | " + phone);
      assert(Augment(augmented, button) == augmented);
    }
    assert(Augment(phone, button) == phone);
    auto commented = "`R Shoulder` /* " + phone + " */";
    assert(Augment(commented, button) == "(" + commented + ") | " + phone);
    auto literal = "'disabled " + phone + "'";
    assert(Augment(literal, button) == "(" + literal + ") | " + phone);
    // No duplicate inputs after switching Touch -> Physical -> Touch.
    auto touch = Augment("`Button " + std::to_string(button) + "`", button);
    auto physical = Augment("`R Shoulder`", button);
    assert(Augment(touch, button) == touch);
    assert(Augment(physical, button) == physical);
  }
  std::cout << "PASS: phone and preserved gamepad/custom binding branches, idempotent hotplug profile changes\n";
}
