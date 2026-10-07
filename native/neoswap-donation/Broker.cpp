#include "Broker.h"

#include <array>
#include <atomic>
#include <mutex>
#include <new>

#if defined(__APPLE__)
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/task_info.h>
#include <mach/vm_statistics.h>
#include <dispatch/dispatch.h>
#include <sys/sysctl.h>
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
struct PressureMonitor {
  dispatch_source_t source = nullptr;
  std::atomic<MemoryPressure> pressure{MemoryPressure::unobserved};
};
void pressure_changed(void* context) {
  auto& monitor = *static_cast<PressureMonitor*>(context);
  const auto flags = dispatch_source_get_data(monitor.source);
  if (flags & DISPATCH_MEMORYPRESSURE_CRITICAL)
    monitor.pressure.store(MemoryPressure::critical, std::memory_order_relaxed);
  else if (flags & DISPATCH_MEMORYPRESSURE_WARN)
    monitor.pressure.store(MemoryPressure::warning, std::memory_order_relaxed);
  else if (flags & DISPATCH_MEMORYPRESSURE_NORMAL)
    monitor.pressure.store(MemoryPressure::normal, std::memory_order_relaxed);
}
PressureMonitor* pressure_monitor() {
  // A process-lifetime subscription: an async callback must never refer to a
  // C++ static whose destructor has already run during application shutdown.
  static PressureMonitor* monitor = new (std::nothrow) PressureMonitor;
  static std::once_flag once;
  if (!monitor) return nullptr;
  std::call_once(once, [&] {
    monitor->source = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0,
        DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN |
        DISPATCH_MEMORYPRESSURE_CRITICAL,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    if (monitor->source) {
      dispatch_set_context(monitor->source, monitor);
      dispatch_source_set_event_handler_f(monitor->source, pressure_changed);
      dispatch_resume(monitor->source);
    }
  });
  return monitor;
}
#if defined(NEOSWAP_TESTING)
std::atomic<std::uint32_t> failed_unmaps{0};
std::atomic<std::uint32_t> failed_right_releases{0};
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
  using HostStatistics = kern_return_t (*)(host_t, host_flavor_t,
      host_info64_t, mach_msg_type_number_t*);
  Create create = nullptr;
  Map map = nullptr;
  Unmap unmap = nullptr;
  Purgeable purgeable = nullptr;
  TaskInfo task_info_call = nullptr;
  HostStatistics host_statistics = nullptr;
  const char* missing = nullptr;

  DarwinAPI() noexcept {
    create = resolve<decltype(create)>("mach_make_memory_entry_64");
    map = resolve<decltype(map)>("mach_vm_map");
    unmap = resolve<decltype(unmap)>("mach_vm_deallocate");
    purgeable = resolve<decltype(purgeable)>("mach_vm_purgable_control");
    task_info_call = resolve<decltype(task_info_call)>("task_info");
    host_statistics = resolve<decltype(host_statistics)>("host_statistics64");
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

kern_return_t release_right(std::uint32_t entry) noexcept {
#if defined(NEOSWAP_TESTING)
  auto count = failed_right_releases.load(std::memory_order_relaxed);
  while (count) if (failed_right_releases.compare_exchange_weak(count, count - 1,
      std::memory_order_relaxed)) return KERN_FAILURE;
#endif
  return mach_port_deallocate(mach_task_self(), entry);
}

bool valid_size(std::size_t bytes) noexcept {
  // Deliberately bounded proof blocks, not a request to fill the device RAM.
  return valid_chunk_size(bytes, vm_page_size);
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

void derive_system_budget(SystemHeadroom& out, std::uint64_t physical_bytes,
                          std::uint32_t kernel_percent, bool valid) noexcept {
  out.kernel_estimate_valid = valid && physical_bytes && kernel_percent <= 100;
  out.kernel_available_percent = out.kernel_estimate_valid ? kernel_percent : 0;
  // memorystatus_level is an integer percentage, not free physical bytes.
  // Round down and reserve a whole percentage point for sample quantization.
  out.kernel_available_bytes = out.kernel_estimate_valid && kernel_percent
      ? (physical_bytes / 100) * (kernel_percent - 1) : 0;
  out.usable_bytes = 0;
  if (out.free_bytes > UINT64_MAX - out.purgeable_bytes) return;
  out.reclaimable_bytes = out.free_bytes + out.purgeable_bytes;
  const auto budget = out.kernel_estimate_valid
      ? out.kernel_available_bytes : out.reclaimable_bytes;
  constexpr std::uint64_t margin = 512ULL * 1024 * 1024;
  if (out.pressure != MemoryPressure::warning && out.pressure != MemoryPressure::critical)
    out.usable_bytes = budget > margin ? budget - margin : 0;
}

Result system_headroom(SystemHeadroom& out) noexcept {
  out = {};
#if defined(__APPLE__)
  if (auto result = availability(); !result) return result;
  auto* monitor = pressure_monitor();
  if (!monitor || !monitor->source) return error(Stage::memory_pressure, KERN_NOT_SUPPORTED);
  out.pressure = monitor->pressure.load(std::memory_order_relaxed);
  std::uint32_t current_pressure = 0;
  size_t pressure_size = sizeof(current_pressure);
  if (sysctlbyname("kern.memorystatus_vm_pressure_level", &current_pressure,
        &pressure_size, nullptr, 0) == 0 && pressure_size == sizeof(current_pressure)) {
    MemoryPressure measured = MemoryPressure::unobserved;
    if (current_pressure == DISPATCH_MEMORYPRESSURE_CRITICAL) measured = MemoryPressure::critical;
    else if (current_pressure == DISPATCH_MEMORYPRESSURE_WARN) measured = MemoryPressure::warning;
    else if (current_pressure == DISPATCH_MEMORYPRESSURE_NORMAL) measured = MemoryPressure::normal;
    if (static_cast<unsigned>(measured) > static_cast<unsigned>(out.pressure)) out.pressure = measured;
  }
  vm_statistics64_data_t memory{};
  mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
  const auto host = mach_host_self();
  const auto kr = api().host_statistics(host, HOST_VM_INFO64,
      reinterpret_cast<host_info64_t>(&memory), &count);
  const auto released = mach_port_deallocate(mach_task_self(), host);
  if (kr != KERN_SUCCESS) return error(Stage::system_headroom, kr);
  if (released != KERN_SUCCESS) return error(Stage::release_entry, released);
  if (count < HOST_VM_INFO64_COUNT || !vm_page_size ||
      memory.free_count > UINT64_MAX / vm_page_size ||
      memory.purgeable_count > UINT64_MAX / vm_page_size)
    return error(Stage::system_headroom, KERN_NOT_SUPPORTED);
  out.free_bytes = static_cast<std::uint64_t>(memory.free_count) * vm_page_size;
  out.purgeable_bytes = static_cast<std::uint64_t>(memory.purgeable_count) * vm_page_size;
  if (out.free_bytes > UINT64_MAX - out.purgeable_bytes)
    return error(Stage::system_headroom, KERN_INVALID_ARGUMENT);
  std::uint64_t physical_bytes = 0;
  std::uint32_t kernel_percent = 0;
  size_t physical_size = sizeof(physical_bytes), percent_size = sizeof(kernel_percent);
  const bool kernel_sample = sysctlbyname("hw.memsize", &physical_bytes, &physical_size, nullptr, 0) == 0 &&
      physical_size == sizeof(physical_bytes) &&
      sysctlbyname("kern.memorystatus_level", &kernel_percent, &percent_size, nullptr, 0) == 0 &&
      percent_size == sizeof(kernel_percent);
  derive_system_budget(out, physical_bytes, kernel_percent, kernel_sample);
  if (out.pressure == MemoryPressure::warning || out.pressure == MemoryPressure::critical) {
    out.usable_bytes = 0;
    return error(Stage::memory_pressure, KERN_RESOURCE_SHORTAGE);
  }
  return {};
#else
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
      const auto kr = release_right(slot.entry);
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
void test_fail_next_right_releases(std::uint32_t count) noexcept {
#if defined(__APPLE__)
  failed_right_releases.store(count, std::memory_order_relaxed);
#else
  (void)count;
#endif
}
#endif

SendRight::~SendRight() {
  const auto result = reset();
#if defined(__APPLE__)
  if (!result && cleanup_slot_ != UINT32_MAX) {
    std::lock_guard guard(cleanup_registry.mutex);
    cleanup_registry.slots[cleanup_slot_] = {true, true, 0, 0, entry_};
    cleanup_registry.last_stage = result.stage;
    cleanup_registry.last_kernel_result = result.kernel_result;
  }
#else
  (void)result;
#endif
}
Result SendRight::prepare() noexcept {
  if (auto result = availability(); !result) return result;
#if defined(__APPLE__)
  if (entry_ || cleanup_slot_ != UINT32_MAX)
    return error(Stage::invalid_argument, KERN_INVALID_ARGUMENT);
  cleanup_slot_ = acquire_cleanup_slot();
  if (cleanup_slot_ == UINT32_MAX)
    return error(Stage::cleanup_limit, KERN_RESOURCE_SHORTAGE);
#endif
  return {};
}
Result SendRight::adopt(std::uint32_t entry) noexcept {
#if defined(__APPLE__)
  if (!entry || entry_ || cleanup_slot_ == UINT32_MAX)
    return error(Stage::invalid_argument, KERN_INVALID_ARGUMENT);
  entry_ = entry;
  return {};
#else
  (void)entry;
  return availability();
#endif
}
Result SendRight::reset() noexcept {
#if defined(__APPLE__)
  if (entry_) {
    const auto kr = release_right(entry_);
    if (kr != KERN_SUCCESS) return error(Stage::release_entry, kr);
    entry_ = 0;
  }
  release_cleanup_slot(cleanup_slot_);
  cleanup_slot_ = UINT32_MAX;
#endif
  return {};
}

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
    const auto kr = release_right(entry_);
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
    case Stage::system_headroom: return "system_headroom";
    case Stage::memory_pressure: return "memory_pressure";
    case Stage::pool_duplicate_pid: return "pool_duplicate_pid";
    case Stage::snapshot_busy: return "snapshot_busy";
    case Stage::pool_busy: return "pool_busy";
  }
  return "unknown";
}

}  // namespace neostation::donation
