#pragma once
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <stdexcept>

namespace neokartpad {
// Layouts checked against the pinned donor's SystemManager::Init,
// UIArchivesHolder::Reset and ArchiveMgr::GetArchive instructions, not just
// incomplete decompilation field names (the latter reverse +5c and +60).
constexpr uint32_t kSystemManager = 0x80386000u;
constexpr uint32_t kArchiveManager = 0x809bd738u;
constexpr uint32_t kSectionManager = 0x809c1e38u;
constexpr uint32_t kTitleFromBoot = 0x3fu;
// 0x40 is NOT a safe host restart. GetSectionPriority(0x40)==5, and
// SectionMgr::ExitSection converts it to a Wii system-reset request.

struct GuestMemory {
  using Pointer = uint8_t* (*)(uint32_t, size_t);
  Pointer pointer = nullptr;
  uint8_t* at(uint32_t address, size_t length) const {
    const uint64_t end = uint64_t(address) + length;
    const bool ram = (address >= 0x80000000u && end <= 0x81800000ull) ||
                     (address >= 0x90000000u && end <= 0x98000000ull);
    if (!pointer || !length || !ram) throw std::runtime_error("invalid guest RAM range");
    auto* result = pointer(address, length);
    if (!result) throw std::runtime_error("guest RAM is unavailable");
    return result;
  }
  uint32_t read32(uint32_t address) const {
    const auto* p = at(address, 4);
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | p[3];
  }
  uint16_t read16(uint32_t address) const {
    const auto* p = at(address, 2);
    return uint16_t((uint16_t(p[0]) << 8) | p[1]);
  }
  void write32(uint32_t address, uint32_t value) const {
    auto* p = at(address, 4);
    p[0] = value >> 24; p[1] = value >> 16;
    p[2] = value >> 8; p[3] = value;
  }
};

struct LanguageState {
  uint32_t system = 0;
  uint32_t archiveLanguage = 0;
  uint32_t requestedLanguage = 0;
  std::array<uint8_t*, 2> suffixes{};
  std::array<std::array<uint8_t, 128>, 2> oldSuffixes{};

  static uint32_t assetLanguage(uint32_t language) {
    if (language < 1 || language > 6) throw std::runtime_error("unsupported PAL language");
    return language == 6 ? 1 : language; // pinned PAL SystemManager::Init mapping
  }
  static const char* suffix(uint32_t language) {
    constexpr const char* names[]{"", "_E.szs", "_G.szs", "_F.szs", "_S.szs", "_I.szs"};
    return names[assetLanguage(language)];
  }
  static LanguageState inspect(const GuestMemory& mem) {
    LanguageState state;
    state.system = mem.read32(kSystemManager);
    state.archiveLanguage = mem.read32(state.system + 0x5c);
    state.requestedLanguage = mem.read32(state.system + 0x60);
    if (state.archiveLanguage < 1 || state.archiveLanguage > 5 ||
        state.requestedLanguage < 1 || state.requestedLanguage > 6)
      throw std::runtime_error("unexpected SystemManager language layout");
    const auto manager = mem.read32(kArchiveManager);
    const auto holders = mem.read32(manager + 4);
    for (size_t index = 0; index < 2; ++index) {
      const uint32_t channel = index == 0 ? 0 : 2; // Race/Common and Scene/UI
      const auto holder = mem.read32(holders + channel * 4);
      if (mem.read16(holder + 8) != 2)
        throw std::runtime_error("unexpected localized archive count");
      const auto pointers = mem.read32(holder + 0x10);
      state.suffixes[index] = mem.at(mem.read32(pointers + 4), 128);
      std::memcpy(state.oldSuffixes[index].data(), state.suffixes[index], 128);
      // An unknown suffix is not permission to overwrite a mod's archive layout.
      bool known = false;
      for (uint32_t language = 1; language <= 5; ++language)
        known |= std::strncmp(reinterpret_cast<const char*>(state.suffixes[index]),
                             suffix(language), 128) == 0;
      if (!known) throw std::runtime_error("unexpected localized archive suffix");
    }
    return state;
  }
  void apply(const GuestMemory& mem, uint32_t language) const {
    const auto asset = assetLanguage(language);
    // inspect validated every destination before the first write. No guest
    // scheduling/callback occurs between these writes and RequestSceneChange.
    mem.write32(system + 0x5c, asset);
    mem.write32(system + 0x60, language);
    for (auto* p : suffixes) {
      std::memset(p, 0, 128);
      std::memcpy(p, suffix(language), std::strlen(suffix(language)));
    }
  }
  void rollback(const GuestMemory& mem) const {
    mem.write32(system + 0x5c, archiveLanguage);
    mem.write32(system + 0x60, requestedLanguage);
    for (size_t i = 0; i < 2; ++i)
      std::memcpy(suffixes[i], oldSuffixes[i].data(), 128);
  }
  bool matches(uint32_t language) const {
    if (archiveLanguage != assetLanguage(language) || requestedLanguage != language) return false;
    for (auto* p : suffixes)
      if (std::strncmp(reinterpret_cast<const char*>(p), suffix(language), 128) != 0) return false;
    return true;
  }
};

// UIKit and frame callbacks are serialized on the runtime's main thread.
// This transaction gives late alert/IO callbacks a generation to validate.
class SessionCommands {
 public:
  enum class Phase { idle, confirming, queued, transitioning, closed };
  uint64_t choose(uint32_t language) {
    if (phase != Phase::idle || closing || language < 1 || language > 6) return 0;
    selected = language; phase = Phase::confirming; return ++generation;
  }
  bool confirm(uint64_t id) {
    if (id != generation || phase != Phase::confirming || closing) return false;
    phase = Phase::queued; frames = 0; return true;
  }
  bool cancel(uint64_t id) {
    if (id != generation || phase != Phase::confirming) return false;
    phase = Phase::idle; selected = 0; ++generation; return true;
  }
  bool requestClose() {
    if (closing || phase == Phase::closed) return false;
    closing = true; selected = 0; frames = 0; ++generation;
    // Let an already accepted transition finish, rather than overwrite it.
    if (phase != Phase::transitioning) phase = Phase::queued;
    return true;
  }
  void accepted() { phase = Phase::transitioning; frames = 0; }
  void complete() { phase = closing ? Phase::closed : Phase::idle; selected = 0; frames = 0; }
  void failed() { phase = Phase::idle; closing = false; selected = 0; frames = 0; ++generation; }
  Phase phase = Phase::idle;
  uint64_t generation = 0;
  uint32_t selected = 0;
  uint32_t frames = 0;
  bool closing = false;
};
} // namespace neokartpad
