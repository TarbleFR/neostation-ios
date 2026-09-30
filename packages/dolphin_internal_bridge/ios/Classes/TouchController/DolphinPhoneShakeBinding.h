// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <string>

namespace DolphinPhoneShakeBinding {
inline bool ContainsControl(const std::string& expression, const std::string& control) {
  // Control-looking text in a block comment or string literal is not an
  // input reference. The pinned parser uses these same delimiters.
  for (size_t offset = 0; offset < expression.size();) {
    if (expression.compare(offset, 2, "/*") == 0) {
      const auto end = expression.find("*/", offset + 2);
      if (end == std::string::npos) return false;
      offset = end + 2;
    } else if (expression[offset] == '\'' || expression[offset] == '`') {
      const char delimiter = expression[offset];
      const auto end = expression.find(delimiter, offset + 1);
      if (end == std::string::npos) return false;
      if (delimiter == '`' && expression.compare(offset, end - offset + 1, control) == 0) return true;
      offset = end + 1;
    } else {
      ++offset;
    }
  }
  return false;
}
// The pinned Dolphin expression parser supports parentheses and | (OR).
// Qualifying the phone source makes it available alongside an MFi default
// device without replacing the user's gamepad or custom shake bindings.
inline std::string Augment(const std::string& current, int button) {
  const std::string phone = "`iOS/4/Touchscreen:Button " + std::to_string(button) + "`";
  if (ContainsControl(current, phone)) return current;
  return current.find_first_not_of(" \t\r\n") == std::string::npos ? phone : "(" + current + ") | " + phone;
}
}
