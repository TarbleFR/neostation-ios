"""Exercise the production CFR clock without Apple frameworks or floating PTS."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class RecordingTimelineTests(unittest.TestCase):
    def test_cfr_resampling_and_bounded_backpressure(self):
        compiler = shutil.which("c++") or shutil.which("clang++")
        if not compiler:
            self.skipTest("C++ compiler unavailable")
        root = Path(__file__).resolve().parents[1]
        include = root / "packages/dolphin_internal_bridge/ios/Classes"
        source = r'''
#include "DolphinRecordingTimeline.h"
#include <cassert>
#include <vector>
using DolphinRecording::Timeline;
int main() {
  Timeline exact;
  std::vector<int64_t> pts;
  while (exact.due(1000000000LL, false)) {
    auto count = exact.drain(1000000000LL, false, [&](int64_t n) {
      pts.push_back(n); return true;
    });
    assert(count <= Timeline::BurstLimit);
  }
  assert(pts.size() == 50);
  for (int i = 0; i < 50; ++i) assert(pts[i] == i);
  assert(exact.nextNanoseconds() == 1000000000LL);

  Timeline jitter;
  int64_t previous = -1;
  unsigned repeated = 0;
  int64_t lastImage = -1;
  // 42 distinct source images are held/repeated on the 50 Hz output grid.
  for (int source = 0; source <= 42; ++source) {
    int64_t incoming = source * 1000000000LL / 42;
    incoming += source % 3 == 0 ? 0 : (source % 3 == 1 ? 400000 : -400000);
    while (jitter.due(incoming) && jitter.nextIndex() < 50) {
      int64_t image = jitter.useIncoming(incoming, previous >= 0) ? source : previous;
      repeated += image == lastImage;
      lastImage = image;
      jitter.accepted();
    }
    previous = source;
  }
  assert(jitter.nextIndex() == 50 && repeated >= 7);

  Timeline sixty;
  unsigned distinct = 0;
  lastImage = previous = -1;
  for (int source = 0; source <= 60; ++source) {
    int64_t incoming = source * 1000000000LL / 60;
    while (sixty.due(incoming) && sixty.nextIndex() < 50) {
      int64_t image = sixty.useIncoming(incoming, previous >= 0) ? source : previous;
      distinct += image != lastImage;
      lastImage = image;
      sixty.accepted();
    }
    previous = source;
  }
  assert(sixty.nextIndex() == 50 && distinct == 50);

  Timeline blocked;
  for (int retry = 0; retry < 100; ++retry)
    assert(blocked.drain(1000000000LL, false, [](int64_t) { return false; }) == 0);
  assert(blocked.nextIndex() == 0);  // Never consume a rejected writer PTS.
  unsigned calls = 0;
  while (blocked.due(5000000000LL, false)) {
    const auto burst = blocked.drain(5000000000LL, false, [](int64_t) { return true; });
    assert(burst <= 4 && burst > 0);
    ++calls;
  }
  assert(calls == 63 && blocked.nextIndex() == 250);
  // A five-second paused picture retains five seconds, not one short burst.
  assert(blocked.nextNanoseconds() == 5000000000LL);
  assert(Timeline::frameCountForDuration(0) == 0);
  assert(Timeline::frameCountForDuration(1) == 1);
  assert(Timeline::frameCountForDuration(1000000000LL) == 50);
  assert(Timeline::frameCountForDuration(1000000001LL) == 51);
  assert(Timeline::frameCountForDuration(6LL * 3600 * 1000000000LL) == 1080000);
  blocked.reset();
  assert(!blocked.due(-1) && blocked.nextIndex() == 0);
}
'''
        with tempfile.TemporaryDirectory(prefix="dolphin-cfr-test-") as temporary:
            folder = Path(temporary)
            cpp = folder / "clock.cpp"
            executable = folder / "clock"
            cpp.write_text(source)
            subprocess.run([compiler, "-std=c++20", "-Wall", "-Wextra", "-Werror",
                            "-I", str(include), str(cpp), "-o", str(executable)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(executable)], check=True, capture_output=True)


if __name__ == "__main__":
    unittest.main()
