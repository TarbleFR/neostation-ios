#pragma once

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <deque>
#include <dlfcn.h>
#include <map>
#include <mutex>
#include <string>
#include <unordered_set>
#include <vector>

namespace neokartpad {

// The official executable was written for one process/one game. RuntimeMain's
// epilogue destroys fibers and Aurora, but not these HLE session objects. Guest
// RAM is zeroed on reentry, so retaining their guest addresses is unsafe.
// Layouts below belong ONLY to the checked v0.5.1 donor. Bind checks the native
// accessors, and the simulator test exercises the same objects through the
// donor's exported functions (not a replacement runtime).
class DonorSessionReset {
 public:
  struct SleepTimer {
    uint32_t thread;
    std::chrono::steady_clock::time_point deadline;
  };
  struct NandCallback { uint32_t callback; int32_t result; uint32_t argument; };
  struct NandFile {
    FILE* file;
    std::string path;
    int32_t mode;
    uint32_t position;
    std::string safeCommitPath;
  };

  static constexpr uintptr_t kCpu = 0x51a9e68;
  static constexpr uintptr_t kVi = 0x51bb2f0;
  static constexpr uintptr_t kAi = 0x4e4e908;
  static constexpr uintptr_t kNandCallbacks = 0x51a9e38;
  static constexpr uintptr_t kNandFiles = 0x5237288;

  bool bind(uint8_t* base, void* handle) {
    if (base_) return base_ == base;
#if defined(__APPLE__)
    static_assert(sizeof(std::mutex) == 64);
    static_assert(sizeof(SleepTimer) == 16);
    static_assert(sizeof(std::deque<NandCallback>) == 48);
    static_assert(sizeof(std::map<int32_t, NandFile>) == 24);
    static_assert(sizeof(NandFile) == 64);
#endif
    // Instructions that address the CPU, VI, AI, NAND deque and NAND tree.
    // Full-function hashes are also checked before packaging the Core.
    // Remaining witnesses are generated from the exact donor, kept alongside
    // the reset layout so drift fails closed before the first session.
    if (!validateWitnesses(base)) return false;
    closeFd_ = reinterpret_cast<void (*)(int32_t)>(dlsym(handle, "_Z7CloseFdi"));
    fibersInitialized_ = reinterpret_cast<bool (*)()>(
        dlsym(handle, "_ZN5Fiber17GuestFiberManager13IsInitializedEv"));
    sleepTimers_ = reinterpret_cast<std::vector<SleepTimer>*>(
        dlsym(handle, "_ZN13OsHleInternal12gSleepTimersE"));
    parks_ = reinterpret_cast<std::unordered_set<uint32_t>*>(
        dlsym(handle, "_ZN13OsHleInternal17gOutstandingParksE"));
    sleepMutex_ = reinterpret_cast<std::mutex*>(
        dlsym(handle, "_ZN13OsHleInternal16gSleepTimerMutexE"));
    parkMutex_ = reinterpret_cast<std::mutex*>(
        dlsym(handle, "_ZN13OsHleInternal21gOutstandingParkMutexE"));
    if (!closeFd_ || !fibersInitialized_ || !sleepTimers_ || !parks_ ||
        !sleepMutex_ || !parkMutex_) return false;
    base_ = base;
    std::memcpy(initialVi_.data(), base_ + kVi, initialVi_.size());
    std::memcpy(initialAi_.data(), base_ + kAi + 64, initialAi_.size());
    std::memcpy(initialCpu_.data(), base_ + kCpu, initialCpu_.size());
    return true;
  }

  // Call only after RuntimeMain returned: AX, renderer and all guest fibers
  // have stopped. No callbacks may run between this reset and Memory::Init.
  bool resetAfterRuntimeReturn() {
    if (!base_ || fibersInitialized_()) return false;
    {
      std::lock_guard lock(*sleepMutex_);
      std::vector<SleepTimer>().swap(*sleepTimers_);
    }
    {
      std::lock_guard lock(*parkMutex_);
      std::unordered_set<uint32_t>().swap(*parks_);
    }
    {
      auto* mutex = at<std::mutex>(0x4e4e568);
      std::lock_guard lock(*mutex);
      std::deque<NandCallback>().swap(*at<std::deque<NandCallback>>(kNandCallbacks));
    }
    // The section transition already completed the guest save operation.
    // Close any remaining host files via the donor's own implementation. Do
    // not publish unfinished NANDSafeOpen scratch files or alter save data.
    auto* files = at<std::map<int32_t, NandFile>>(kNandFiles);
    while (!files->empty()) closeFd_(files->begin()->first);

    // Shutdown destroys registered fibers; fibers that exited on their own
    // stack are kept in this separate deferred-delete list until a switch.
    // There is no further switch after RuntimeMain returns, so release them
    // here with the same stack/object delete operations as the donor.
    auto* pendingFibers = at<std::vector<void*>>(0x52061f0);
    for (void* fiber : *pendingFibers) {
      if (!fiber) continue;
      void* stack = nullptr;
      std::memcpy(&stack, static_cast<uint8_t*>(fiber) + 0x420, sizeof(stack));
      if (stack) ::operator delete[](stack);
      ::operator delete(fiber);
    }
    std::vector<void*>().swap(*pendingFibers);

    std::memcpy(base_ + kCpu, initialCpu_.data(), initialCpu_.size());
    {
      std::lock_guard lock(*at<std::mutex>(0x4e58038));
      std::memcpy(base_ + kVi, initialVi_.data(), initialVi_.size());
    }
    {
      std::lock_guard lock(*at<std::mutex>(kAi));
      std::memcpy(base_ + kAi + 64, initialAi_.data(), initialAi_.size());
    }
    at<std::atomic_bool>(0x4e4e688)->store(true);
    *at<uint32_t>(0x5206230) = 0; // guest interrupt mask
    *at<uint32_t>(0x5206210) = 0; // current guest thread
    at<std::atomic<uint32_t>>(0x5206218)->store(0); // queued retraces
    at<std::atomic_bool>(0x5348560)->store(false); // active Aurora frame
    at<std::atomic_bool>(0x5348561)->store(false); // frame had work
    at<std::atomic_bool>(0x51bb2d0)->store(false); // retrace callback in progress
    at<std::atomic_bool>(0x51bb2d1)->store(false); // present sequence in progress
    *at<int32_t>(0x53482c4) = 0; // guest frame counter
    // Fiber destruction does not unwind suspended C++ stack scopes. These
    // TLS recursion counters must not suppress callbacks in the next guest.
    *tls<int>(0x51a2d68) = 0;
    *tls<int>(0x51a2e58) = 0;
    return true;
  }

 private:
  template<class T> T* at(uintptr_t offset) { return reinterpret_cast<T*>(base_ + offset); }
  template<class T> T* tls(uintptr_t offset) {
    void* descriptor = base_ + offset;
    auto get = *reinterpret_cast<void* (**)(void*)>(descriptor);
    return static_cast<T*>(get(descriptor));
  }
  static bool matches(const uint8_t* p, std::initializer_list<uint8_t> bytes) {
    return std::memcmp(p, bytes.begin(), bytes.size()) == 0;
  }
  static bool validateWitnesses(const uint8_t* base);
  uint8_t* base_ = nullptr;
  std::array<uint8_t, 144> initialVi_{};
  std::array<uint8_t, 48> initialAi_{};
  std::array<uint8_t, 464> initialCpu_{};
  std::vector<SleepTimer>* sleepTimers_ = nullptr;
  std::unordered_set<uint32_t>* parks_ = nullptr;
  std::mutex* sleepMutex_ = nullptr;
  std::mutex* parkMutex_ = nullptr;
  void (*closeFd_)(int32_t) = nullptr;
  bool (*fibersInitialized_)() = nullptr;
};

inline bool DonorSessionReset::validateWitnesses(const uint8_t* base) {
  return matches(base + 0x5bfbc, {0x68,0x8a,0x02,0xd0,0x09,0x71,0x4e,0xb9,0xa9,0x00,0x00,0x34,0x68,0x8a,0x02,0xd0,0x09,0x9d,0x4e,0xb9,0x09,0x01,0x00,0x34,0xc0,0x03,0x5f,0xd6,0x09,0xf4,0x9d,0x52,0x09,0x07,0xb0,0x72,0x09,0x71,0x0e,0xb9,0x68,0x8a,0x02,0xd0,0x09,0x9d,0x4e,0xb9,0x49,0xff,0xff,0x35,0x09,0x80,0x99,0x52,0x09,0x07,0xb0,0x72,0x09,0x9d,0x0e,0xb9,0xc0,0x03,0x5f,0xd6}) &&
         matches(base + 0x191dac, {0x20,0x66,0x02,0xf0,0x00,0xe0,0x00,0x91,0x44,0xc9,0x0e,0x95,0x48,0x81,0x02,0xd0,0x08,0xc1,0x4b,0x39,0xc8,0x01,0x00,0x37,0x54,0x81,0x02,0xd0,0x94,0xc2,0x0b,0x91,0x0a,0xc4,0x89,0x52,0x88,0x06,0x40,0xb9,0x29,0x00,0x80,0x52,0x89,0x02,0x00,0x39,0x1f,0x05,0x00,0x71,0x48,0x23,0x88,0x52,0x48,0x01,0x88,0x9a,0x88,0x26,0x00,0xf9,0x45,0xc9,0x0e,0x95,0x80,0x22,0x00,0xf9,0x86,0xfd,0xff,0x97}) &&
         matches(base + 0x113b2c, {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xd3,0x69,0x02,0xf0,0x73,0x22,0x24,0x91,0xe0,0x03,0x13,0xaa,0xe0,0xc1,0x10,0x95,0xe0,0x03,0x13,0xaa,0x7f,0x42,0x01,0x39,0x7f,0x46,0x00,0xb9,0x7f,0x5a,0x00,0xb9,0x7f,0x32,0x00,0xf9,0xdd,0xc1,0x10,0x95,0xfd,0x7b,0x41,0xa9,0xf4,0x4f,0xc2,0xa8,0x01,0x00,0x00,0x14,0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0x28,0x85,0x02,0xd0,0x08,0x01,0x12,0x91,0x08,0xfd,0xdf,0x08,0x48,0x05,0x00,0x36,0x61,0x0d,0x00,0x94,0xf3,0x84,0x02,0xf0,0x73,0x42,0x08,0x91,0xe0,0x03,0x13,0xaa,0xcb,0xc1,0x10,0x95}) &&
         matches(base + 0x5ceb8, {0xf5,0x03,0x00,0x2a,0x80,0x6f,0x02,0xd0,0x00,0xa0,0x15,0x91,0xf3,0x03,0x02,0x2a,0xf4,0x03,0x01,0x2a,0xfe,0x9c,0x13,0x95,0x76,0x8a,0x02,0xb0,0xd6,0x02,0x39,0x91,0xab,0x2a,0x80,0x52,0xc8,0x2a,0x40,0xa9}) &&
         matches(base + 0x92c5c, {0xe0,0x6d,0x02,0x90,0x00,0x60,0x1f,0x91,0x98,0xc5,0x12,0x95,0x28,0x8d,0x02,0xb0,0x13,0x49,0x41,0xf9,0x13,0x01,0x00,0xb5}) &&
         matches(base + 0x67d98, {0x60,0x12,0x42,0xf9,0x7f,0x12,0x02,0xf9,0x40,0x00,0x00,0xb4,0xc3,0x71,0x13,0x95,0xe0,0x03,0x13,0xaa,0xc4,0x71,0x13,0x95,0xc0,0x89,0x02,0xf0,0x00,0xa0,0x38,0x91,0x9f,0x06,0x01,0xf9,0x08,0x00,0x40,0xf9,0x00,0x01,0x3f,0xd6,0x1f,0x00,0x00,0xf9});
}

} // namespace neokartpad
