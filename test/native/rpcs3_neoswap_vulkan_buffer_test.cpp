// Fault-injected Vulkan calls execute the actual imported-buffer implementation.
// GPU execution is a separate macOS/iPhone validation, never inferred here.
#include <cassert>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>
using u64 = std::uint64_t;
using u32 = std::uint32_t;
using VkDevice = std::uintptr_t;
using VkBuffer = std::uintptr_t;
using VkDeviceMemory = std::uintptr_t;
constexpr auto VK_NULL_HANDLE = 0;
constexpr auto VK_SUCCESS = 0;
constexpr u64 VK_WHOLE_SIZE = UINT64_MAX;
constexpr auto VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT = 1u;
constexpr auto VK_MEMORY_PROPERTY_HOST_COHERENT_BIT = 2u;
constexpr auto VK_EXTERNAL_MEMORY_HANDLE_TYPE_HOST_ALLOCATION_BIT_EXT = 1u;
constexpr auto VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT = 1u;
enum {
 VK_STRUCTURE_TYPE_MEMORY_HOST_POINTER_PROPERTIES_EXT,
 VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
 VK_STRUCTURE_TYPE_IMPORT_MEMORY_HOST_POINTER_INFO_EXT,
 VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
 VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_BUFFER_INFO,
 VK_STRUCTURE_TYPE_EXTERNAL_BUFFER_PROPERTIES,
 VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_MEMORY_HOST_PROPERTIES_EXT,
 VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2,
 VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_BUFFER_CREATE_INFO
};
struct VkBufferCreateInfo { u32 sType{}; const void* pNext{}; u32 flags{}; u64 size{}; u32 usage{}; };
struct VkMemoryHostPointerPropertiesEXT { u32 sType; const void* pNext{}; u32 memoryTypeBits{}; };
struct VkMemoryDedicatedAllocateInfo { u32 sType; const void* pNext{}; std::uintptr_t image{}; VkBuffer buffer{}; };
struct VkImportMemoryHostPointerInfoEXT { u32 sType; const void* pNext{}; u32 handleType{}; void* pHostPointer{}; };
struct VkMemoryAllocateInfo { u32 sType; const void* pNext{}; u64 allocationSize{}; u32 memoryTypeIndex{}; };
struct VkPhysicalDeviceExternalBufferInfo { u32 sType; const void* pNext{}; u32 flags{}; u32 usage{}; u32 handleType{}; };
struct VkExternalMemoryProperties { u32 externalMemoryFeatures{}; u32 exportFromImportedHandleTypes{}; u32 compatibleHandleTypes{}; };
struct VkExternalBufferProperties { u32 sType; const void* pNext{}; VkExternalMemoryProperties externalMemoryProperties{}; };
struct VkPhysicalDeviceExternalMemoryHostPropertiesEXT { u32 sType; const void* pNext{}; u64 minImportedHostPointerAlignment{}; };
struct VkPhysicalDeviceProperties2 { u32 sType; void* pNext{}; };
struct VkExternalMemoryBufferCreateInfo { u32 sType; const void* pNext{}; u32 handleTypes{}; };
struct VkMemoryRequirements { u64 size{}; u64 alignment{}; u32 memoryTypeBits{}; };
static constexpr u64 MiB = 1024 * 1024;
static int fault = 0, queries = 0, release_errors = 0;
static bool extension = true, enabled = true, can_import = true;
static u64 host_alignment = 16384, memory_alignment = 256, requirement_size = MiB;
static u32 host_bits = 3, required_bits = 3, selected_type = 0;
static std::vector<std::string> events;
static void* loan = nullptr;
static void* tracked_handle = nullptr;
static u64 tracked_bytes = 0;
struct logger { template<class... T> void error(const char*, T...) { ++release_errors; } } rsx_log;
static void ensure(bool value) { if (!value) throw std::out_of_range("mapping"); }
namespace vk {
enum vmm_allocation_pool { VMM_ALLOCATION_POOL_SYSTEM, VMM_ALLOCATION_POOL_TEXTURE_CACHE };
static void vmm_notify_memory_allocated(void* handle, u32 type, u64 bytes, vmm_allocation_pool pool) {
 assert(!tracked_handle && handle && type == selected_type && pool == VMM_ALLOCATION_POOL_SYSTEM);
 tracked_handle = handle; tracked_bytes = bytes; events.push_back("track-vmm");
}
static void vmm_notify_memory_freed(void* handle) {
 assert(handle == tracked_handle && tracked_bytes == requirement_size);
 tracked_handle = nullptr; tracked_bytes = 0; events.push_back("free-vmm");
}
struct render_device {
 operator VkDevice() const { return 9; }
 auto gpu() const { return 8; }
 bool get_external_memory_host_support() const { return extension; }
 bool get_compatible_memory_type(u32 bits, u32 flags, u32* type) const {
  assert(flags == 3); if (!bits) return false;
  *type = (bits & 1) ? 0 : 1; return true;
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
 u64 size() const { return m_size; }
};
}
static void vkGetPhysicalDeviceExternalBufferProperties(int, const VkPhysicalDeviceExternalBufferInfo* info, VkExternalBufferProperties* out) {
 ++queries; assert(info->usage == 7 && info->flags == 0);
 out->externalMemoryProperties = {can_import ? 1u : 0u, 0, 1};
}
static void vkGetPhysicalDeviceProperties2(int, VkPhysicalDeviceProperties2* props) {
 static_cast<VkPhysicalDeviceExternalMemoryHostPropertiesEXT*>(props->pNext)->minImportedHostPointerAlignment = host_alignment;
}
static int vkCreateBuffer(VkDevice, const VkBufferCreateInfo* info, void*, VkBuffer* out) {
 events.push_back("create"); assert(info->pNext);
 assert(static_cast<const VkExternalMemoryBufferCreateInfo*>(info->pNext)->handleTypes == 1);
 if (fault == 1) return -1; *out = 19; return 0;
}
static void vkGetBufferMemoryRequirements(VkDevice, VkBuffer, VkMemoryRequirements* out) { *out = {requirement_size, memory_alignment, required_bits}; }
static int pointer_properties(VkDevice, u32 kind, const void* pointer, VkMemoryHostPointerPropertiesEXT* out) {
 events.push_back("pointer"); assert(kind == 1 && pointer == loan);
 if (fault == 2) return -1; out->memoryTypeBits = host_bits; return 0;
}
static auto _vkGetMemoryHostPointerPropertiesEXT = &pointer_properties;
static int vkAllocateMemory(VkDevice, const VkMemoryAllocateInfo* info, void*, VkDeviceMemory* out) {
 events.push_back("allocate-vk");
 auto imported = static_cast<const VkImportMemoryHostPointerInfoEXT*>(info->pNext);
 auto dedicated = static_cast<const VkMemoryDedicatedAllocateInfo*>(imported->pNext);
 assert(imported->pHostPointer == loan && dedicated->buffer == 19 && !dedicated->image);
 assert(info->allocationSize == requirement_size && info->memoryTypeIndex < 2);
 selected_type = info->memoryTypeIndex;
 if (fault == 3) return -1; *out = 29; return 0;
}
static int vkBindBufferMemory(VkDevice, VkBuffer buffer, VkDeviceMemory memory, u64 offset) {
 events.push_back("bind"); assert(buffer == 19 && memory == 29 && offset == 0);
 return fault == 4 ? -1 : 0;
}
static void vkDestroyBuffer(VkDevice, VkBuffer, void*) { events.push_back("destroy-buffer"); }
static void vkFreeMemory(VkDevice, VkDeviceMemory, void*) { assert(loan); events.push_back("free-vk"); }
#include "rpcs3/ios/NeoSwapVulkanBuffer.h"
static int allocate_loan(u32 owner, u32 kind, u64 bytes, u64 alignment, void** out) {
 // Imports identify themselves with the additive GPU host-visible kind.
 assert(owner == NEOSWAP_RPCS3 && kind == NEOSWAP_GPU_HOST_VISIBLE);
 events.push_back("loan"); if (fault == 5) return NEOSWAP_QUOTA;
 assert(!loan && alignment == 16384); loan = std::aligned_alloc(alignment, bytes);
 assert(loan); *out = loan; return NEOSWAP_OK;
}
static int release_loan(void* pointer) {
 assert(pointer == loan); events.push_back("release-loan");
 if (fault == 6) return NEOSWAP_MAPPING;
 std::free(loan); loan = nullptr; return NEOSWAP_OK;
}
static int sync_loan(void*) { return NEOSWAP_OK; }
static int is_enabled(u32) { return enabled; }
static void reset() {
 assert(!loan && !tracked_handle && !tracked_bytes); fault = queries = release_errors = 0; extension = enabled = can_import = true;
 host_alignment = 16384; memory_alignment = 256; requirement_size = MiB;
 host_bits = required_bits = 3; events.clear();
}
int main() {
 const NeoSwapAPI api{sizeof(NeoSwapAPI), NEOSWAP_ABI, allocate_loan, release_loan, sync_loan, is_enabled};
 assert(neostation::swap::install(&api) == NEOSWAP_OK);
 vk::render_device device;
 VkBufferCreateInfo info{}; info.size = MiB; info.usage = 7;
 auto attempt = [&](u32 access = 3, vk::vmm_allocation_pool pool = vk::VMM_ALLOCATION_POOL_SYSTEM) {
  VkBuffer output = 0; std::unique_ptr<vk::memory_block> memory;
  const bool result = vk::try_neoswap_buffer(device, info, access, pool, output, memory);
  if (result) {
   assert(output == 19 && memory->size() == MiB);
   assert(tracked_handle == memory.get() && tracked_bytes == MiB);
   assert(memory->map(0, MiB) == loan); std::memset(memory->map(0, MiB), 0x3c, MiB);
   assert(memory->map(0, VK_WHOLE_SIZE) == loan);
   assert(static_cast<unsigned char*>(memory->map(MiB-1, 1))[0] == 0x3c);
   assert(memory->get_vk_device_memory_offset() == 0);
   bool bounds = false; try { memory->map(MiB, 1); } catch (const std::out_of_range&) { bounds = true; }
   assert(bounds); memory->unmap();
   // Stand in for buffer::~buffer, after deferred GPU completion.
   vkDestroyBuffer(device, output, nullptr); memory.reset();
  } else assert(!output && !memory);
  assert(!tracked_handle && !tracked_bytes);
  return result;
 };
 reset(); assert(attempt());
 assert((events == std::vector<std::string>{"create","loan","pointer","allocate-vk","track-vmm","bind","destroy-buffer","free-vmm","free-vk","release-loan"}));
 reset(); host_bits = 2; assert(attempt() && selected_type == 1); // actual intersection, not first generic type
 for (int stage = 1; stage <= 5; ++stage) {
  reset(); fault = stage; assert(!attempt() && !loan);
  if (stage == 4) assert((std::vector<std::string>(events.end()-4,events.end()) == std::vector<std::string>{"destroy-buffer","free-vmm","free-vk","release-loan"}));
 }
 reset(); host_bits = 0; assert(!attempt() && !loan);
 reset(); required_bits = 0; assert(!attempt() && !loan);
 reset(); can_import = false; assert(!attempt() && events.empty());
 reset(); extension = false; assert(!attempt() && !queries);
 reset(); _vkGetMemoryHostPointerPropertiesEXT = nullptr; assert(!attempt() && !queries); _vkGetMemoryHostPointerPropertiesEXT = pointer_properties;
 reset(); enabled = false; assert(!attempt() && !loan);
 reset(); host_alignment = 3; assert(!attempt() && events.empty());
 reset(); host_alignment = 131072; assert(!attempt() && events.empty());
 reset(); memory_alignment = 131072; assert(!attempt() && events.back() == "destroy-buffer");
 reset(); requirement_size = MiB-1; assert(!attempt() && !loan);
 reset(); requirement_size = 256*MiB+1; assert(!attempt() && !loan);
 reset(); info.size = MiB-1; assert(!attempt() && !queries); info.size = MiB;
 reset(); info.size = 256*MiB+1; assert(!attempt() && !queries); info.size = MiB;
 reset(); assert(!attempt(4) && !queries);
 reset(); assert(!attempt(3,vk::VMM_ALLOCATION_POOL_TEXTURE_CACHE) && !queries);
 reset(); info.flags = 1; assert(!attempt() && !queries); info.flags = 0;
 reset(); info.pNext = &api; assert(!attempt() && !queries); info.pNext = nullptr;
 reset(); fault = 6; assert(attempt() && loan && release_errors == 1); // broker retains on failed unmap
 std::free(loan); loan = nullptr;
 std::cout << "PASS: production Vulkan import; pointer/type/alignment/capability refusals; failure cleanup; deferred buffer-memory-loan lifetime\n";
}
