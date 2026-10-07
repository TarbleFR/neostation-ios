// macOS proof only. Compile the canonical RPCS3 import implementation against
// real Vulkan, the pinned MoltenVK driver and the actual host donation broker.
#pragma once
#include <vulkan/vulkan.h>
#include "Pool.h"
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include "RetirementProof.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <memory>
#include <unordered_map>
#include <vector>

using u64 = std::uint64_t;
using u32 = std::uint32_t;
static PFN_vkGetMemoryHostPointerPropertiesEXT _vkGetMemoryHostPointerPropertiesEXT;
// Probe observer increments this only after an authenticated, accepted donor
// ledger update. It provides a freshness boundary after the GPU fence.
static std::atomic<u64> vulkanDonorLedgerEpoch{0};
static void ensure(bool value) { require(value, "Vulkan borrowed mapping exceeds its extent"); }
struct VulkanProbeLogger {
  template<class... T> void error(const char* message, T...) {
    std::fprintf(stderr, "%s\n", message);
  }
};
static VulkanProbeLogger rsx_log;
namespace vk {
enum vmm_allocation_pool { VMM_ALLOCATION_POOL_SYSTEM };
static std::unordered_map<void*, u64> trackedAllocations;
static u64 trackedBytes = 0;
static void vmm_notify_memory_allocated(void* handle, u32, u64 bytes, vmm_allocation_pool pool) {
  require(pool == VMM_ALLOCATION_POOL_SYSTEM && trackedAllocations.emplace(handle, bytes).second,
          "Canonical Vulkan import duplicated its renderer budget entry");
  trackedBytes += bytes;
}
static void vmm_notify_memory_freed(void* handle) {
  const auto entry = trackedAllocations.find(handle);
  require(entry != trackedAllocations.end(), "Canonical Vulkan import lost its renderer budget entry");
  trackedBytes -= entry->second; trackedAllocations.erase(entry);
}
struct render_device {
  VkDevice handle;
  VkPhysicalDevice physical;
  operator VkDevice() const { return handle; }
  VkPhysicalDevice gpu() const { return physical; }
  bool get_external_memory_host_support() const { return true; }
  bool get_compatible_memory_type(u32 bits, u32 flags, u32* output) const {
    VkPhysicalDeviceMemoryProperties properties{};
    vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    for (u32 index = 0; index < properties.memoryTypeCount; ++index)
      if ((bits & (1u << index)) && (properties.memoryTypes[index].propertyFlags & flags) == flags) {
        *output = index; return true;
      }
    return false;
  }
};
struct memory_block {
  u64 m_size;
  explicit memory_block(u64 size) : m_size(size) {}
  virtual ~memory_block() = default;
  virtual VkDeviceMemory get_vk_device_memory() = 0;
  virtual u64 get_vk_device_memory_offset() = 0;
  virtual void* map(u64, u64) = 0;
  virtual void unmap() = 0;
};
}
// This is the materialized production header, not a probe-specific import copy.
#include "rpcs3/ios/NeoSwapVulkanBuffer.h"

static NSDictionary* runVulkanDonationProbe(NeoSwapDonorSession* session, uint64_t target) {
  evidence[@"stage"] = @"vulkan_driver";
  // Direct MoltenVK linking does not use the Vulkan loader's portability
  // enumeration extension. Enable it only when the actual instance exposes it.
  u32 instanceExtensionCount = 0;
  require(vkEnumerateInstanceExtensionProperties(nullptr, &instanceExtensionCount, nullptr) == VK_SUCCESS,
          "Vulkan instance extension enumeration failed");
  std::vector<VkExtensionProperties> instanceProperties(instanceExtensionCount);
  require(vkEnumerateInstanceExtensionProperties(nullptr, &instanceExtensionCount, instanceProperties.data()) == VK_SUCCESS,
          "Vulkan instance extension properties failed");
  const bool portability = std::any_of(instanceProperties.begin(), instanceProperties.end(), [](const auto& property) {
    return std::strcmp(property.extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0;
  });
  const char* instanceExtensions[] = {VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME};
  VkApplicationInfo app{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  app.pApplicationName = "NeoSwap canonical RPCS3 buffer proof";
  app.apiVersion = VK_API_VERSION_1_2;
  VkInstanceCreateInfo instanceInfo{VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO};
  instanceInfo.pApplicationInfo = &app;
  if (portability) {
    instanceInfo.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    instanceInfo.enabledExtensionCount = 1;
    instanceInfo.ppEnabledExtensionNames = instanceExtensions;
  }
  VkInstance instance = VK_NULL_HANDLE;
  require(vkCreateInstance(&instanceInfo, nullptr, &instance) == VK_SUCCESS, "MoltenVK instance creation failed");
  u32 count = 0;
  require(vkEnumeratePhysicalDevices(instance, &count, nullptr) == VK_SUCCESS && count,
          "No physical Vulkan GPU is available");
  std::vector<VkPhysicalDevice> physicals(count);
  require(vkEnumeratePhysicalDevices(instance, &count, physicals.data()) == VK_SUCCESS,
          "Vulkan GPU enumeration failed");
  VkPhysicalDevice physical = physicals.front();
  VkPhysicalDeviceProperties properties{};
  vkGetPhysicalDeviceProperties(physical, &properties);
  require(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, nullptr) == VK_SUCCESS,
          "Vulkan extension enumeration failed");
  std::vector<VkExtensionProperties> extensions(count);
  require(vkEnumerateDeviceExtensionProperties(physical, nullptr, &count, extensions.data()) == VK_SUCCESS,
          "Vulkan extension properties failed");
  const auto supported = [&](const char* name) {
    return std::any_of(extensions.begin(), extensions.end(), [&](const auto& value) {
      return std::strcmp(value.extensionName, name) == 0;
    });
  };
  require(supported(VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME), "MoltenVK cannot import host pointers");
  std::vector<const char*> enabled{VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME};
  if (supported("VK_KHR_portability_subset")) enabled.push_back("VK_KHR_portability_subset");
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, nullptr);
  std::vector<VkQueueFamilyProperties> queues(count);
  vkGetPhysicalDeviceQueueFamilyProperties(physical, &count, queues.data());
  u32 family = UINT32_MAX;
  for (u32 i = 0; i < count; ++i)
    if (queues[i].queueCount && (queues[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)) { family = i; break; }
  require(family != UINT32_MAX, "Vulkan graphics queue unavailable");
  const float priority = 1;
  VkDeviceQueueCreateInfo queueInfo{VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  queueInfo.queueFamilyIndex = family; queueInfo.queueCount = 1; queueInfo.pQueuePriorities = &priority;
  VkDeviceCreateInfo deviceInfo{VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  deviceInfo.queueCreateInfoCount = 1; deviceInfo.pQueueCreateInfos = &queueInfo;
  deviceInfo.enabledExtensionCount = static_cast<u32>(enabled.size());
  deviceInfo.ppEnabledExtensionNames = enabled.data();
  VkDevice device = VK_NULL_HANDLE;
  require(vkCreateDevice(physical, &deviceInfo, nullptr, &device) == VK_SUCCESS, "Vulkan device creation failed");
  _vkGetMemoryHostPointerPropertiesEXT = reinterpret_cast<PFN_vkGetMemoryHostPointerPropertiesEXT>(
      vkGetDeviceProcAddr(device, "vkGetMemoryHostPointerPropertiesEXT"));
  require(_vkGetMemoryHostPointerPropertiesEXT, "Vulkan host-pointer query is not callable");
  vk::render_device renderer{device, physical};
  VkQueue queue = VK_NULL_HANDLE;
  vkGetDeviceQueue(device, family, 0, &queue);
  VkCommandPoolCreateInfo commandPoolInfo{VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO};
  commandPoolInfo.queueFamilyIndex = family;
  VkCommandPool commandPool = VK_NULL_HANDLE;
  require(vkCreateCommandPool(device, &commandPoolInfo, nullptr, &commandPool) == VK_SUCCESS,
          "Vulkan command pool failed");
  VkCommandBufferAllocateInfo commands{VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO};
  commands.commandPool = commandPool; commands.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY; commands.commandBufferCount = 1;
  VkCommandBuffer command = VK_NULL_HANDLE;
  require(vkAllocateCommandBuffers(device, &commands, &command) == VK_SUCCESS, "Vulkan command allocation failed");
  VkFenceCreateInfo fenceInfo{VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkFence fence = VK_NULL_HANDLE;
  require(vkCreateFence(device, &fenceInfo, nullptr, &fence) == VK_SUCCESS, "Vulkan fence allocation failed");

  const auto snapshot = session.snapshot;
  require(snapshot.state == NeoSwapDonorStateActive && snapshot.capacityBytes == target,
          "Vulkan requires a fully verified live donor");
  using namespace neostation::donation;
  require(bool(pool_campaign_begin(snapshot.generation, target)) &&
          bool(pool_donor_begin(snapshot.generation, 0, snapshot.generation, snapshot.donorPID)),
          "Production donation pool refused the authenticated donor");
  for (u64 index = 0; index < snapshot.verifiedChunkCount; ++index) {
    const auto right = [session copyMemoryEntryForChunk:index];
    require(right != MACH_PORT_NULL, "Verified Vulkan chunk has no owned Mach right");
    const auto adopted = pool_adopt_donor(snapshot.generation, 0, snapshot.generation, index,
        right, [session chunkCapacityBytes:index]);
    const auto released = mach_port_deallocate(mach_task_self(), right);
    require(bool(adopted) && released == KERN_SUCCESS, "Production donor pool adoption failed");
  }
  Footprint donor{};
  donor.physical = snapshot.donorFootprintBytes;
  donor.nonvolatile = snapshot.donorNonvolatileBytes;
  donor.nonvolatile_compressed = snapshot.donorCompressedBytes;
  require(bool(pool_verify_donor(snapshot.generation, 0, snapshot.generation, target, donor,
          snapshot.donatedResidentBytes, snapshot.donatedCompressedBytes)), "Production pool ledger verification failed");
  NeoSwapConfig config{};
  config.struct_size = sizeof(config); config.abi_version = NEOSWAP_ABI;
  config.capacity_bytes = target; config.minimum_allocation_bytes = MiB;
  config.enabled_owner_mask = 1u << NEOSWAP_RPCS3;
  // An absent arena makes a file-backed substitute impossible in this proof.
  require(NeoSwap_Configure("/neoswap-proof-absent-directory", &config) == NEOSWAP_STORAGE,
          "Vulkan proof unexpectedly configured a file arena");
  require(neostation::swap::install(NeoSwap_GetAPI(NEOSWAP_ABI)) == NEOSWAP_OK,
          "Canonical RPCS3 client rejected the production vtable");

  struct BorrowedBuffer { VkBuffer handle; std::unique_ptr<vk::memory_block> memory; u64 bytes; };
  std::vector<BorrowedBuffer> buffers;
  Footprint before{}, after{};
  require(bool(footprint(before)), "Vulkan host baseline ledger failed");
  u64 imported = 0;
  for (u64 index = 0; index < snapshot.verifiedChunkCount; ++index) {
    evidence[@"stage"] = @"vulkan_canonical_import";
    VkBufferCreateInfo info{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
    info.size = [session chunkCapacityBytes:index];
    info.usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
    VkBuffer handle = VK_NULL_HANDLE;
    std::unique_ptr<vk::memory_block> memory;
    require(vk::try_neoswap_buffer(renderer, info,
        VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        vk::VMM_ALLOCATION_POOL_SYSTEM, handle, memory), "Canonical RPCS3 Vulkan import refused verified donor pages");
    imported += info.size;
    buffers.push_back({handle, std::move(memory), info.size});
  }
  NeoSwapHostStats host{};
  NeoSwapStats broker{};
  broker.struct_size = sizeof(broker);
  require(imported == target && NeoSwap_HostSnapshot(&host) == NEOSWAP_OK &&
          host.owner_donated_live_bytes[NEOSWAP_RPCS3] == target &&
          NeoSwap_LiveBytes(NEOSWAP_RPCS3) == target && host.reserved_virtual_bytes == 0 &&
          host.file_ready_owner_mask == 0 && NeoSwap_Snapshot(&broker) == NEOSWAP_OK &&
          broker.allocated_disk_bytes == 0,
          "Imported buffers are not actual RPCS3-owned donation loans");
  require(vk::trackedBytes == target, "Canonical Vulkan imports omitted the renderer memory budget");
  evidence[@"vulkanDonatedLiveBytes"] = @(host.owner_donated_live_bytes[NEOSWAP_RPCS3]);
  evidence[@"stage"] = @"vulkan_gpu_fill";
  VkCommandBufferBeginInfo begin{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
  begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
  require(vkBeginCommandBuffer(command, &begin) == VK_SUCCESS, "Vulkan command recording failed");
  for (const auto& buffer : buffers) vkCmdFillBuffer(command, buffer.handle, 0, buffer.bytes, 0x3c3c3c3c);
  VkMemoryBarrier barrier{VK_STRUCTURE_TYPE_MEMORY_BARRIER};
  barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT; barrier.dstAccessMask = VK_ACCESS_HOST_READ_BIT;
  vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_HOST_BIT, 0,
      1, &barrier, 0, nullptr, 0, nullptr);
  require(vkEndCommandBuffer(command) == VK_SUCCESS, "Vulkan command finalization failed");
  VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
  submit.commandBufferCount = 1; submit.pCommandBuffers = &command;
  require(vkQueueSubmit(queue, 1, &submit, fence) == VK_SUCCESS, "Vulkan GPU submission failed");
  // require exits without unwinding borrowed mappings on timeout/device loss.
  require(vkWaitForFences(device, 1, &fence, VK_TRUE, 30ULL * 1000000000) == VK_SUCCESS,
          "Vulkan GPU command incomplete; process exit preserves mapping lifetime");
  for (const auto& buffer : buffers) {
    const auto* bytes = static_cast<const unsigned char*>(buffer.memory->map(0, buffer.bytes));
    for (u64 offset = 0; offset < buffer.bytes; offset += vm_page_size)
      require(bytes[offset] == 0x3c, "Vulkan GPU writes did not reach the borrowed donor alias");
    require(bytes[buffer.bytes - 1] == 0x3c, "Vulkan GPU last-byte write mismatch");
  }
  evidence[@"stage"] = @"vulkan_fresh_donor_ledger";
  const auto epoch = vulkanDonorLedgerEpoch.load(std::memory_order_acquire);
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(4);
  // One update may already be in flight at the fence. The donor permits only
  // one pending update: its second new reply necessarily measures pages after
  // completion, rather than merely delivering an older sample afterwards.
  while (vulkanDonorLedgerEpoch.load(std::memory_order_acquire) < epoch + 2 &&
         std::chrono::steady_clock::now() < deadline) usleep(20000);
  require(vulkanDonorLedgerEpoch.load(std::memory_order_acquire) >= epoch + 2,
          "Vulkan proof received no fresh authenticated donor ledger after GPU completion");
  const auto finalDonor = session.snapshot;
  evidence[@"vulkanDonorResidentAfterGPUBytes"] = @(finalDonor.donatedResidentBytes);
  evidence[@"vulkanDonorCompressedAfterGPUBytes"] = @(finalDonor.donatedCompressedBytes);
  require(finalDonor.state == NeoSwapDonorStateActive && finalDonor.donorPID == snapshot.donorPID &&
          finalDonor.generation == snapshot.generation && finalDonor.capacityBytes == target &&
          finalDonor.donatedResidentBytes >= target - MiB &&
          finalDonor.donatedCompressedBytes <= MiB,
          "Vulkan donor no longer owns the requested resident pages after GPU completion");
  require(NeoSwap_HostSnapshot(&host) == NEOSWAP_OK &&
          host.owner_donated_live_bytes[NEOSWAP_RPCS3] == target &&
          NeoSwap_LiveBytes(NEOSWAP_RPCS3) == target,
          "Vulkan loans changed before the refreshed donor ledger was measured");
  require(bool(footprint(after)), "Vulkan host final ledger failed");
  const auto nonvolatile = after.nonvolatile > before.nonvolatile ? after.nonvolatile - before.nonvolatile : 0;
  const auto physicalDelta = after.physical > before.physical ? after.physical - before.physical : 0;
  evidence[@"vulkanHostNonvolatileDeltaBytes"] = @(nonvolatile);
  evidence[@"vulkanHostFootprintDeltaBytes"] = @(physicalDelta);
  require(nonvolatile < MiB && physicalDelta < 64 * MiB, "Vulkan imported pages charged substantial memory to the host");
  evidence[@"stage"] = @"vulkan_retirement";
  NeoSwapFastStats beforeRetirement{};
  require(NeoSwap_FastSnapshot(&beforeRetirement) == NEOSWAP_OK,
          "Vulkan retirement could not snapshot FAST ownership");
  for (auto& buffer : buffers) { vkDestroyBuffer(device, buffer.handle, nullptr); buffer.memory.reset(); }
  require(vk::trackedBytes == 0 && vk::trackedAllocations.empty(), "Vulkan retirement retained renderer budget entries");
  const auto retirement = prove_fast_retirement(buffers.size(), target, beforeRetirement);
  // Record failed drains as well as successful ones. The final strict leak
  // assertion stays mandatory; waiting never substitutes for actual ownership.
  NSDictionary* retirementEvidence = @{
      @"retirementQueuedLoans":@(retirement.queued_loans), @"retirementQueuedBytes":@(retirement.queued_bytes),
      @"retirementCompletedLoans":@(retirement.completed_loans), @"retirementPendingLoans":@(retirement.pending_loans),
      @"retirementMaintenancePasses":@(retirement.passes), @"retirementMaintenanceLimit":@(retirement.maximum_passes),
      @"retirementFailureCount":@(retirement.failures), @"retirementElapsedUs":@(retirement.elapsed_us),
      @"retiredPoolLiveBytes":@(retirement.pool_live_bytes), @"retiredPoolLiveBlocks":@(retirement.pool_live_blocks),
      @"retiredHostLiveBytes":@(retirement.host_live_bytes), @"retiredDonatedLiveBytes":@(retirement.donated_live_bytes)};
  evidence[@"vulkanRetirement"] = retirementEvidence;
  require(retirement.passed && NeoSwap_LiveBytes(NEOSWAP_RPCS3) == 0 &&
          NeoSwap_HostSnapshot(&host) == NEOSWAP_OK && host.owner_donated_live_bytes[NEOSWAP_RPCS3] == 0,
          "Vulkan retirement retained live donation loans");
  pool_donor_lost(snapshot.generation, 0, snapshot.generation, 0);
  require(bool(pool_collect_lost()), "Vulkan donor mappings could not be retired");
  vkDestroyFence(device, fence, nullptr); vkDestroyCommandPool(device, commandPool, nullptr);
  vkDestroyDevice(device, nullptr); vkDestroyInstance(instance, nullptr);
  NSMutableDictionary* result = [@{@"passed":@YES, @"device":[NSString stringWithUTF8String:properties.deviceName],
      @"importedBytes":@(imported), @"donatedLiveBytesDuringGPU":@(target), @"retiredLiveBytes":@0,
      @"bufferCount":@(buffers.size()), @"gpuWrittenBytes":@(imported), @"gpuToCpuAliasVerified":@YES,
      @"productionRPCS3ImportPath":@YES, @"productionHostBroker":@YES,
      @"allocatedDiskBytesDuringGPU":@(broker.allocated_disk_bytes),
      @"fileArenaConfigured":@NO,
      @"rendererBudgetDuringGPU":@(target), @"rendererBudgetAfterRetirement":@0,
      @"donorLedgerRefreshedAfterGPU":@YES,
      @"donorResidentAfterGPUBytes":@(finalDonor.donatedResidentBytes),
      @"donorCompressedAfterGPUBytes":@(finalDonor.donatedCompressedBytes),
      @"hostNonvolatileDeltaBytes":@(nonvolatile), @"hostFootprintDeltaBytes":@(physicalDelta),
      @"realRPCS3GameplayValidated":@NO, @"realIPhoneValidated":@NO} mutableCopy];
  [result addEntriesFromDictionary:retirementEvidence];
  return result;
}
