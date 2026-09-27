#pragma once

#include <cstddef>
#include <vector>

namespace neokartpad {

// The SDL game window can remain UIKit's key window briefly after the donor
// restores NeoStation. Key-window status does not establish Flutter ownership.
struct HostWindowCandidate {
  bool flutterOwned;
  bool attached;
  bool visible;
  bool foreground;
  bool key;
};

inline int SelectHostWindow(const std::vector<HostWindowCandidate>& candidates) {
  for (size_t index = 0; index < candidates.size(); ++index) {
    const auto& candidate = candidates[index];
    if (candidate.flutterOwned && candidate.attached && candidate.visible &&
        candidate.foreground) {
      return static_cast<int>(index);
    }
  }
  return -1;
}

}  // namespace neokartpad
