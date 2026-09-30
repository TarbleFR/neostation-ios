#include "Broker.h"

#include <array>
#include <atomic>
#include <mutex>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/task_info.h>
#include <mach/vm_statistics.h>
#endif

namespace neostation::donation {

#if defined(__APPLE__)
namespace {
constexpr std::size_t cleanup_slots = 1024;
struct CleanupDescriptor {
  bool in_use = false;
  bool pending = false;
  std::uint64_t address = 0;
  std::size_t bytes = 0;
  std::uint32_t entry = 0;
};
struct CleanupRegistry {
  std::mutex mutex;
  std::array<CleanupDescriptor, cleanup_slots> slots{};
  Stage last_stage = Stage::none;
  std::int32_t last_kernel_result = 0;
};
// Constructed before runtime Block/Pool instances, so their destructors can
// quarantine resources without allocating or relying on destroyed statics.
CleanupRegistry cleanup_registry;
#if defined(NEOSWAP_TESTING)
std::atomic<std::uint32_t> failed_unmaps{0};
#endif

std::uint32_t acquire_cleanup_slot() noexcept {
  std::lock_guard guard(cleanup_registry.mutex);
  for (std::size_t i = 0; i < cleanup_registry.slots.size(); ++i) {
    auto& slot = cleanup_registry.slots[i];
    if (!slot.in_use) {
      slot.in_use = true;
      return static_cast<std::uint32_t>(i);
    }
  }
  return UINT32_MAX;
}
void release_cleanup_slot(std::uint32_t slot) noexcept {
  if (slot == UINT32_MAX) return;
  std::lock_guard guard(cleanup_registry.mutex);
  cleanup_registry.slots[slot] = {};
}

struct DarwinAPI {
  // Explicit signatures avoid taking the address of an SDK declaration marked
  // macOS-only. These are runtime probes, never eager undefined Mach VM imports.
  using Create = kern_return_t (*)(vm_map_t, memory_object_size_t*,
      memory_object_offset_t, vm_prot_t, mach_port_t*, mem_entry_name_port_t);
  // mach_vm.h is absent from iPhoneOS SDKs. The 64-bit address/size arguments
  // below preserve the exported Mach ABI without importing that macOS header.
  using Map = kern_return_t (*)(vm_map_t, std::uint64_t*, std::uint64_t,
      std::uint64_t, int, mem_entry_name_port_t, memory_object_offset_t,
      boolean_t, vm_prot_t, vm_prot_t, vm_inherit_t);
  using Unmap = kern_return_t (*)(vm_map_t, std::uint64_t, std::uint64_t);
  using Purgeable = kern_return_t (*)(vm_map_t, std::uint64_t, vm_purgable_t, int*);
  using TaskInfo = kern_return_t (*)(task_name_t, task_flavor_t,
      task_info_t, mach_msg_type_number_t*);
  Create create = nullptr;
  Map map = nullptr;
  Unmap unmap = nullptr;
  Purgeable purgeable = nullptr;
  TaskInfo task_info_call = nullptr;
  const char* missing = nullptr;

  DarwinAPI() noexcept {
    create = resolve<decltype(create)>("mach_make_memory_entry_64");
    map = resolve<decltype(map)>("mach_vm_map");
    unmap = resolve<decltype(unmap)>("mach_vm_deallocate");
    purgeable = resolve<decltype(purgeable)>("mach_vm_purgable_control");
    task_info_call = resolve<decltype(task_info_call)>("task_info");
  }

  template <typename T>
  T resolve(const char* name) noexcept {
    auto symbol = reinterpret_cast<T>(dlsym(RTLD_DEFAULT, name));
    if (!symbol && !missing) missing = name;
    return symbol;
  }
};

const DarwinAPI& api() noexcept {
  static const DarwinAPI instance;
  return instance;
}

Result error(Stage stage, kern_return_t kr) noexcept { return {stage, kr}; }

kern_return_t unmap(std::uint64_t address, std::size_t bytes) noexcept {
#if defined(NEOSWAP_TESTING)
  auto count = failed_unmaps.load(std::memory_order_relaxed);
  while (count) if (failed_unmaps.compare_exchange_weak(count, count - 1,
      std::memory_order_relaxed)) return KERN_FAILURE;
#endif
  return api().unmap(mach_task_self(), address, bytes);
}

bool valid_size(std::size_t bytes) noexcept {
  // Deliberately bounded proof blocks, not a request to fill the device RAM.
  constexpr std::size_t max = 256ULL * 1024 * 1024;
  return bytes && bytes <= max && bytes % vm_page_size == 0;
}
}  // namespace
#endif

Result availability() noexcept {
#if defined(__APPLE__)
  if (api().missing) return {Stage::unavailable, KERN_NOT_SUPPORTED, api().missing};
  return {};
#else
  return {Stage::unavailable, -1, "Darwin Mach VM"};
#endif
}

Result footprint(Footprint& out) noexcept {
#if defined(__APPLE__)
  if (auto result = availability(); !result) return result;
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  const auto kr = api().task_info_call(mach_task_self(), TASK_VM_INFO,
      reinterpret_cast<task_info_t>(&info), &count);
  if (kr != KERN_SUCCESS) return error(Stage::footprint, kr);
  if (count < TASK_VM_INFO_REV3_COUNT || info.ledger_purgeable_nonvolatile < 0 ||
      info.ledger_purgeable_novolatile_compressed < 0)
    return error(Stage::footprint_revision, KERN_NOT_SUPPORTED);
  out = {info.phys_footprint, info.resident_size, info.internal,
         static_cast<std::uint64_t>(info.ledger_purgeable_nonvolatile),
         static_cast<std::uint64_t>(info.ledger_purgeable_novolatile_compressed)};
  return {};
#else
  (void)out;
  return availability();
#endif
}

Result retry_cleanup() noexcept {
#if defined(__APPLE__)
  if (auto result = availability(); !result) return result;
  auto& registry = cleanup_registry;
  std::lock_guard guard(registry.mutex);
  Result first{};
  for (auto& slot : registry.slots) if (slot.pending) {
    if (slot.address) {
      const auto kr = api().unmap(mach_task_self(), slot.address, slot.bytes);
      if (kr != KERN_SUCCESS) {
        if (first) first = error(Stage::unmap, kr);
        continue;
      }
      slot.address = 0;
      slot.bytes = 0;
    }
    if (slot.entry) {
      const auto kr = mach_port_deallocate(mach_task_self(), slot.entry);
      if (kr != KERN_SUCCESS) {
        if (first) first = error(Stage::release_entry, kr);
        continue;
      }
    }
    slot = {};
  }
  registry.last_stage = first.stage;
  registry.last_kernel_result = first.kernel_result;
  return first;
#else
  return availability();
#endif
}

void cleanup_snapshot(CleanupSnapshot& out) noexcept {
  out = {};
#if defined(__APPLE__)
  std::lock_guard guard(cleanup_registry.mutex);
  for (const auto& slot : cleanup_registry.slots) if (slot.pending) {
    ++out.pending_blocks;
    out.pending_mappings += slot.address != 0;
    out.pending_rights += slot.entry != 0;
  }
  out.last_stage = cleanup_registry.last_stage;
  out.last_kernel_result = cleanup_registry.last_kernel_result;
#endif
}

#if defined(NEOSWAP_TESTING)
void test_fail_next_unmaps(std::uint32_t count) noexcept {
#if defined(__APPLE__)
  failed_unmaps.store(count, std::memory_order_relaxed);
#else
  (void)count;
#endif
}
#endif

Block::~Block() {
  const auto result = reset();
#if defined(__APPLE__)
  if (!result && cleanup_slot_ != UINT32_MAX) {
    std::lock_guard guard(cleanup_registry.mutex);
    auto& slot = cleanup_registry.slots[cleanup_slot_];
    slot = {true, true, address_, bytes_, entry_};
    cleanup_registry.last_stage = result.stage;
    cleanup_registry.last_kernel_result = result.kernel_result;
    address_ = 0;
    bytes_ = 0;
    entry_ = 0;
    cleanup_slot_ = UINT32_MAX;
  }
#else
  (void)result;
#endif
}

Result Block::create_owned(std::size_t bytes, Block& out) noexcept {
#if defined(__APPLE__)
  if (auto result = availability(); !result) return result;
  if (!valid_size(bytes) || out.address_ || out.entry_ || out.cleanup_slot_ != UINT32_MAX)
    return error(Stage::invalid_argument, KERN_INVALID_ARGUMENT);
  const auto slot = acquire_cleanup_slot();
  if (slot == UINT32_MAX) return error(Stage::cleanup_limit, KERN_RESOURCE_SHORTAGE);
  memory_object_size_t size = bytes;
  mach_port_t entry = MACH_PORT_NULL;
  const auto kr = api().create(mach_task_self(), &size, 0,
      VM_PROT_READ | VM_PROT_WRITE | MAP_MEM_NAMED_CREATE | MAP_MEM_PURGABLE,
      &entry, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS) {
    release_cleanup_slot(slot);
    return error(Stage::create_entry, kr);
  }
  out.cleanup_slot_ = slot;
  out.entry_ = entry;
  if (size != bytes || entry == MACH_PORT_NULL) {
    if (auto cleanup = out.reset(); !cleanup) return cleanup;
    return error(Stage::create_entry, KERN_INVALID_ARGUMENT);
  }
  auto result = map_retained(entry, bytes, out);
  if (!result) if (auto cleanup = out.reset(); !cleanup) return cleanup;
  return result;
#else
  (void)bytes;
  (void)out;
  return availability();
#endif
}

Result Block::map_borrowed(std::uint32_t entry, std::size_t bytes,
                           Block& out) noexcept {
#if defined(__APPLE__)
  if (auto result = availability(); !result) return result;
  if (!valid_size(bytes) || !entry || out.address_ || out.entry_ || out.cleanup_slot_ != UINT32_MAX)
    return error(Stage::invalid_argument, KERN_INVALID_ARGUMENT);
  const auto slot = acquire_cleanup_slot();
  if (slot == UINT32_MAX) return error(Stage::cleanup_limit, KERN_RESOURCE_SHORTAGE);
  const auto kr = mach_port_mod_refs(mach_task_self(), entry, MACH_PORT_RIGHT_SEND, 1);
  if (kr != KERN_SUCCESS) {
    release_cleanup_slot(slot);
    return error(Stage::retain_entry, kr);
  }
  out.cleanup_slot_ = slot;
  out.entry_ = entry;
  auto result = map_retained(entry, bytes, out);
  if (!result) if (auto cleanup = out.reset(); !cleanup) return cleanup;
  return result;
#else
  (void)entry;
  (void)bytes;
  (void)out;
  return availability();
#endif
}

Result Block::map_retained(std::uint32_t entry, std::size_t bytes,
                           Block& out) noexcept {
#if defined(__APPLE__)
  std::uint64_t address = 0;
  auto kr = api().map(mach_task_self(), &address, bytes, 65535, VM_FLAGS_ANYWHERE,
      entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
      VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE);
  if (kr != KERN_SUCCESS) return error(Stage::map_entry, kr);
  int state = 0;
  kr = api().purgeable(mach_task_self(), address, VM_PURGABLE_GET_STATE, &state);
  if (kr != KERN_SUCCESS || (state & VM_PURGABLE_STATE_MASK) != VM_PURGABLE_NONVOLATILE) {
    const auto unmap_result = api().unmap(mach_task_self(), address, bytes);
    if (unmap_result != KERN_SUCCESS) {
      // Preserve the live mapping/right so that reset can retry safely.
      out.address_ = address;
      out.bytes_ = bytes;
      out.entry_ = entry;
      return error(Stage::unmap, unmap_result);
    }
    return error(kr == KERN_SUCCESS ? Stage::wrong_purgeable_state : Stage::query_nonvolatile,
                 kr == KERN_SUCCESS ? KERN_INVALID_ARGUMENT : kr);
  }
  out.address_ = address;
  out.bytes_ = bytes;
  out.entry_ = entry;
  return {};
#else
  (void)entry;
  (void)bytes;
  (void)out;
  return availability();
#endif
}

Result Block::reset() noexcept {
#if defined(__APPLE__)
  if (address_) {
    const auto kr = unmap(address_, bytes_);
    if (kr != KERN_SUCCESS) return error(Stage::unmap, kr);
    address_ = 0;
    bytes_ = 0;
  }
  if (entry_) {
    const auto kr = mach_port_deallocate(mach_task_self(), entry_);
    if (kr != KERN_SUCCESS) return error(Stage::release_entry, kr);
    entry_ = 0;
  }
  bytes_ = 0;
  release_cleanup_slot(cleanup_slot_);
  cleanup_slot_ = UINT32_MAX;
#endif
  return {};
}

const char* stage_name(Stage stage) noexcept {
  switch (stage) {
    case Stage::none: return "ok";
    case Stage::unavailable: return "unavailable";
    case Stage::invalid_argument: return "invalid_argument";
    case Stage::create_entry: return "create_entry";
    case Stage::retain_entry: return "retain_entry";
    case Stage::map_entry: return "map_entry";
    case Stage::query_nonvolatile: return "query_nonvolatile";
    case Stage::wrong_purgeable_state: return "wrong_purgeable_state";
    case Stage::unmap: return "unmap";
    case Stage::release_entry: return "release_entry";
    case Stage::footprint: return "footprint";
    case Stage::footprint_revision: return "footprint_revision";
    case Stage::pool_unready: return "pool_unready";
    case Stage::pool_quota: return "pool_quota";
    case Stage::pool_limit: return "pool_limit";
    case Stage::pool_not_owned: return "pool_not_owned";
    case Stage::cleanup_limit: return "cleanup_limit";
  }
  return "unknown";
}

}  // namespace neostation::donation
