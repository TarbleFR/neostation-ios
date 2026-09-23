#!/usr/bin/env python3
"""Exercise the real native message-queue code during concurrent shutdown."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "native/dusklight/upstream/src/dusk/stubs.cpp").read_text()
queue = source[source.index("struct PCMessageQueueData"):source.index("// Remaining OS Stubs")]
prefix = r'''
#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <future>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
using s32 = int;
using BOOL = int;
using OSMessage = void*;
constexpr int OS_MESSAGE_BLOCK = 1, OS_MESSAGE_NOBLOCK = 0;
struct OSThreadQueue { void *head, *tail; };
struct OSMessageQueue {
  OSThreadQueue queueSend, queueReceive;
  OSMessage* msgArray;
  s32 msgCount, firstIndex, usedCount;
};
namespace dusk { std::atomic<bool> IsShuttingDown{false}; }
'''
test = r'''
int main() {
  using namespace std::chrono_literals;
  for (int iteration = 0; iteration < 100; ++iteration) {
    dusk::IsShuttingDown = false;
    OSMessageQueue empty{}, full{};
    OSMessage emptyStorage[1]{}, fullStorage[1]{};
    OSInitMessageQueue(&empty, emptyStorage, 1);
    OSInitMessageQueue(&full, fullStorage, 1);
    void* payload = reinterpret_cast<void*>(0x1234);
    assert(OSSendMessage(&full, payload, OS_MESSAGE_NOBLOCK) == 1);
    OSMessage received{};
    assert(OSReceiveMessage(&full, &received, OS_MESSAGE_NOBLOCK) == 1);
    assert(received == payload);
    assert(OSSendMessage(&full, payload, OS_MESSAGE_NOBLOCK) == 1);
    auto* waitingQueue = &GetMsgQueueData(&empty);
    auto reader = std::async(std::launch::async, [&] {
      return OSReceiveMessage(&empty, nullptr, OS_MESSAGE_BLOCK);
    });
    auto writer = std::async(std::launch::async, [&] {
      return OSSendMessage(&full, payload, OS_MESSAGE_BLOCK);
    });
    dusk::IsShuttingDown = true;
    ClearMsgQueueMap();
    assert(reader.wait_for(1s) == std::future_status::ready);
    assert(writer.wait_for(1s) == std::future_status::ready);
    assert(reader.get() == 0);
    assert(writer.get() == 0);
    // The old implementation cleared the table while the futures held these
    // mutex/CV addresses. The embedded implementation keeps their ownership.
    assert(GetMsgQueueMap().at(&empty).get() == waitingQueue);
    GetMsgQueueMap().clear(); // Safe here: both worker futures have completed.
  }
}
'''
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / "queue.cpp"
    executable = Path(directory) / "queue-test"
    cpp.write_text(prefix + queue + test)
    subprocess.run(["c++", "-std=c++20", "-pthread", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=20)

main = (ROOT / "native/dusklight/upstream/src/m_Do/m_Do_main.cpp").read_text()
reset = main.index("OSResetSystem(OS_RESET_SHUTDOWN, 0, 0)")
join = main.index("NeoDusklight_JoinGameThreads()", reset)
shutdown = main.index("aurora_shutdown()", join)
assert reset < join < shutdown
print("PASS: real Dusklight queues wake safely; workers join before Aurora teardown")
