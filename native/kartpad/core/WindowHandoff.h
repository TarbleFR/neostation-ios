#pragma once

namespace neokartpad {

// The host and donor windows are captured by the current session. Hide only
// that donor window, then restore the host before reporting sessionEnded.
template <typename Window, typename Hide, typename Show>
inline void RestoreOwnedWindow(Window* host, Window* donor, Hide hide, Show show) {
  if (donor && donor != host) hide(donor);
  if (host) show(host);
}

} // namespace neokartpad
