/*
 * Vulkan libretro test core for the iOS Simulator probe
 * (test/libretro_simulator_probe.py). It uses the frontend's Vulkan context
 * the way Azahar 2126.2 does (src/citra_libretro): it creates the VkDevice
 * in the negotiation interface's create_device and leaves its destruction
 * to the frontend (destroy_device NULL, "frontend owns the device"), renders
 * every frame into its own image with its own command buffers, and in
 * retro_unload_game waits for the device and destroys its objects through
 * the device it reads from the frontend's hardware render interface at that
 * moment (Azahar: PresentWindow::~PresentWindow, vulkan_intf->device). A
 * frontend that releases the device before retro_unload_game makes these
 * calls use a destroyed VkDevice, which is how closing a 3DS game ended
 * NeoStation. Each step is logged ("neovk ...").
 */
#define VK_NO_PROTOTYPES 1
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <vulkan/vulkan.h>

#include "libretro.h"
#include "libretro_vulkan.h"

#define WIDTH 320
#define HEIGHT 240
#define COMMAND_BUFFERS 4

static retro_environment_t environ_cb;
static retro_video_refresh_t video_cb;
static retro_input_poll_t input_poll_cb;
static retro_log_printf_t log_cb;
static struct retro_hw_render_callback hw;
static const struct retro_hw_render_interface_vulkan *vulkan;

static PFN_vkDeviceWaitIdle device_wait_idle;
static PFN_vkCreateImage create_image;
static PFN_vkDestroyImage destroy_image;
static PFN_vkGetImageMemoryRequirements image_memory_requirements;
static PFN_vkAllocateMemory allocate_memory;
static PFN_vkFreeMemory free_memory;
static PFN_vkBindImageMemory bind_image_memory;
static PFN_vkCreateImageView create_image_view;
static PFN_vkDestroyImageView destroy_image_view;
static PFN_vkCreateCommandPool create_command_pool;
static PFN_vkDestroyCommandPool destroy_command_pool;
static PFN_vkAllocateCommandBuffers allocate_command_buffers;
static PFN_vkResetCommandBuffer reset_command_buffer;
static PFN_vkBeginCommandBuffer begin_command_buffer;
static PFN_vkEndCommandBuffer end_command_buffer;
static PFN_vkCmdPipelineBarrier pipeline_barrier;
static PFN_vkCmdClearColorImage clear_color_image;

static VkImage image;
static VkDeviceMemory memory;
static VkImageView view;
static VkImageViewCreateInfo view_info;
static VkCommandPool pool;
static VkCommandBuffer commands[COMMAND_BUFFERS];
static bool resources;
static unsigned frame;

static void note(enum retro_log_level level, const char *text) {
  if (log_cb) log_cb(level, "neovk %s\n", text);
}

static const VkApplicationInfo *application_info(void) {
  static VkApplicationInfo info = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "NeoVulkanTest",
      .applicationVersion = 1,
      .pEngineName = "NeoVulkanTest",
      .engineVersion = 1,
      .apiVersion = VK_API_VERSION_1_1,
  };
  return &info;
}

/* Like LibRetro::CreateVulkanDevice: the core creates the device. */
static bool create_device(struct retro_vulkan_context *context, VkInstance instance, VkPhysicalDevice gpu,
                          VkSurfaceKHR surface, PFN_vkGetInstanceProcAddr get_instance_proc_addr,
                          const char **required_extensions, unsigned required_extension_count,
                          const char **required_layers, unsigned required_layer_count,
                          const VkPhysicalDeviceFeatures *required_features) {
  (void)surface;
  PFN_vkGetPhysicalDeviceQueueFamilyProperties families_of =
      (PFN_vkGetPhysicalDeviceQueueFamilyProperties)get_instance_proc_addr(instance,
                                                                           "vkGetPhysicalDeviceQueueFamilyProperties");
  PFN_vkCreateDevice create = (PFN_vkCreateDevice)get_instance_proc_addr(instance, "vkCreateDevice");
  PFN_vkGetDeviceQueue queue_of = (PFN_vkGetDeviceQueue)get_instance_proc_addr(instance, "vkGetDeviceQueue");
  if (families_of == NULL || create == NULL || queue_of == NULL) return false;
  uint32_t count = 0;
  families_of(gpu, &count, NULL);
  VkQueueFamilyProperties families[16];
  if (count > 16) count = 16;
  families_of(gpu, &count, families);
  uint32_t family = UINT32_MAX;
  for (uint32_t index = 0; index < count && family == UINT32_MAX; index++) {
    if (families[index].queueFlags & VK_QUEUE_GRAPHICS_BIT) family = index;
  }
  if (family == UINT32_MAX) return false;
  const float priority = 1.0f;
  VkDeviceQueueCreateInfo queue_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = family,
      .queueCount = 1,
      .pQueuePriorities = &priority,
  };
  VkDeviceCreateInfo device_info = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queue_info,
      .enabledExtensionCount = required_extension_count,
      .ppEnabledExtensionNames = required_extensions,
      .enabledLayerCount = required_layer_count,
      .ppEnabledLayerNames = required_layers,
      .pEnabledFeatures = required_features,
  };
  VkDevice device = VK_NULL_HANDLE;
  if (create(gpu, &device_info, NULL, &device) != VK_SUCCESS) {
    note(RETRO_LOG_ERROR, "create_device: vkCreateDevice failed");
    return false;
  }
  VkQueue queue = VK_NULL_HANDLE;
  queue_of(device, family, 0, &queue);
  context->gpu = gpu;
  context->device = device;
  context->queue = queue;
  context->queue_family_index = family;
  context->presentation_queue = queue;
  context->presentation_queue_family_index = family;
  note(RETRO_LOG_INFO, "create_device: device created by the core");
  return true;
}

#define DEVICE_FUNCTION(target, name) \
  target = (__typeof__(target))vulkan->get_device_proc_addr(vulkan->device, name)

static uint32_t memory_type(uint32_t bits, VkMemoryPropertyFlags wanted) {
  PFN_vkGetPhysicalDeviceMemoryProperties properties_of = (PFN_vkGetPhysicalDeviceMemoryProperties)
      vulkan->get_instance_proc_addr(vulkan->instance, "vkGetPhysicalDeviceMemoryProperties");
  VkPhysicalDeviceMemoryProperties properties;
  memset(&properties, 0, sizeof(properties));
  if (properties_of != NULL) properties_of(vulkan->gpu, &properties);
  for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
    if ((bits & (1u << index)) && (properties.memoryTypes[index].propertyFlags & wanted) == wanted) return index;
  }
  for (uint32_t index = 0; index < properties.memoryTypeCount; index++) {
    if (bits & (1u << index)) return index;
  }
  return 0;
}

static void context_reset(void) {
  vulkan = NULL;
  if (!environ_cb(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE, (void *)&vulkan) || vulkan == NULL ||
      vulkan->interface_type != RETRO_HW_RENDER_INTERFACE_VULKAN) {
    note(RETRO_LOG_ERROR, "context_reset: no Vulkan render interface");
    return;
  }
  DEVICE_FUNCTION(device_wait_idle, "vkDeviceWaitIdle");
  DEVICE_FUNCTION(create_image, "vkCreateImage");
  DEVICE_FUNCTION(destroy_image, "vkDestroyImage");
  DEVICE_FUNCTION(image_memory_requirements, "vkGetImageMemoryRequirements");
  DEVICE_FUNCTION(allocate_memory, "vkAllocateMemory");
  DEVICE_FUNCTION(free_memory, "vkFreeMemory");
  DEVICE_FUNCTION(bind_image_memory, "vkBindImageMemory");
  DEVICE_FUNCTION(create_image_view, "vkCreateImageView");
  DEVICE_FUNCTION(destroy_image_view, "vkDestroyImageView");
  DEVICE_FUNCTION(create_command_pool, "vkCreateCommandPool");
  DEVICE_FUNCTION(destroy_command_pool, "vkDestroyCommandPool");
  DEVICE_FUNCTION(allocate_command_buffers, "vkAllocateCommandBuffers");
  DEVICE_FUNCTION(reset_command_buffer, "vkResetCommandBuffer");
  DEVICE_FUNCTION(begin_command_buffer, "vkBeginCommandBuffer");
  DEVICE_FUNCTION(end_command_buffer, "vkEndCommandBuffer");
  DEVICE_FUNCTION(pipeline_barrier, "vkCmdPipelineBarrier");
  DEVICE_FUNCTION(clear_color_image, "vkCmdClearColorImage");
  VkImageCreateInfo image_info = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
      .imageType = VK_IMAGE_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .extent = {WIDTH, HEIGHT, 1},
      .mipLevels = 1,
      .arrayLayers = 1,
      .samples = VK_SAMPLE_COUNT_1_BIT,
      .tiling = VK_IMAGE_TILING_OPTIMAL,
      .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_SAMPLED_BIT,
      .sharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
  };
  if (create_image(vulkan->device, &image_info, NULL, &image) != VK_SUCCESS) {
    note(RETRO_LOG_ERROR, "context_reset: vkCreateImage failed");
    return;
  }
  VkMemoryRequirements requirements;
  image_memory_requirements(vulkan->device, image, &requirements);
  VkMemoryAllocateInfo allocation = {
      .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
      .allocationSize = requirements.size,
      .memoryTypeIndex = memory_type(requirements.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT),
  };
  if (allocate_memory(vulkan->device, &allocation, NULL, &memory) != VK_SUCCESS ||
      bind_image_memory(vulkan->device, image, memory, 0) != VK_SUCCESS) {
    note(RETRO_LOG_ERROR, "context_reset: image memory unavailable");
    return;
  }
  view_info = (VkImageViewCreateInfo){
      .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
      .image = image,
      .viewType = VK_IMAGE_VIEW_TYPE_2D,
      .format = VK_FORMAT_R8G8B8A8_UNORM,
      .components = {VK_COMPONENT_SWIZZLE_R, VK_COMPONENT_SWIZZLE_G, VK_COMPONENT_SWIZZLE_B, VK_COMPONENT_SWIZZLE_A},
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
  };
  VkCommandPoolCreateInfo pool_info = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
      .queueFamilyIndex = vulkan->queue_index,
  };
  VkCommandBufferAllocateInfo buffers = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = COMMAND_BUFFERS,
  };
  if (create_image_view(vulkan->device, &view_info, NULL, &view) != VK_SUCCESS ||
      create_command_pool(vulkan->device, &pool_info, NULL, &pool) != VK_SUCCESS) {
    note(RETRO_LOG_ERROR, "context_reset: view or command pool unavailable");
    return;
  }
  buffers.commandPool = pool;
  if (allocate_command_buffers(vulkan->device, &buffers, commands) != VK_SUCCESS) {
    note(RETRO_LOG_ERROR, "context_reset: command buffers unavailable");
    return;
  }
  resources = true;
  note(RETRO_LOG_INFO, "context_reset: image, view and command buffers ready");
}

static void context_destroy(void) {
  /* Like Azahar with Vulkan: nothing is released here. */
  note(RETRO_LOG_INFO, "context_destroy");
}

static void barrier(VkCommandBuffer command, VkImageLayout from, VkImageLayout to, VkAccessFlags src, VkAccessFlags dst,
                    VkPipelineStageFlags src_stage, VkPipelineStageFlags dst_stage) {
  VkImageMemoryBarrier transition = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = src,
      .dstAccessMask = dst,
      .oldLayout = from,
      .newLayout = to,
      .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
      .image = image,
      .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1},
  };
  pipeline_barrier(command, src_stage, dst_stage, 0, 0, NULL, 0, NULL, 1, &transition);
}

RETRO_API void retro_set_environment(retro_environment_t cb) { environ_cb = cb; }
RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb) { video_cb = cb; }
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb) { (void)cb; }
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { (void)cb; }
RETRO_API void retro_set_input_poll(retro_input_poll_t cb) { input_poll_cb = cb; }
RETRO_API void retro_set_input_state(retro_input_state_t cb) { (void)cb; }

RETRO_API void retro_init(void) {
  struct retro_log_callback logging;
  if (environ_cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &logging)) log_cb = logging.log;
  note(RETRO_LOG_INFO, "init");
}

RETRO_API void retro_deinit(void) { note(RETRO_LOG_INFO, "deinit"); }
RETRO_API unsigned retro_api_version(void) { return RETRO_API_VERSION; }

RETRO_API void retro_get_system_info(struct retro_system_info *info) {
  memset(info, 0, sizeof(*info));
  info->library_name = "NeoVulkanTest";
  info->library_version = "1.0";
  info->valid_extensions = "ntc|vkt";
  info->need_fullpath = false;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info) {
  memset(info, 0, sizeof(*info));
  info->geometry.base_width = WIDTH;
  info->geometry.base_height = HEIGHT;
  info->geometry.max_width = WIDTH;
  info->geometry.max_height = HEIGHT;
  info->geometry.aspect_ratio = 4.0f / 3.0f;
  info->timing.fps = 60.0;
  info->timing.sample_rate = 48000.0;
}

RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device) {
  (void)port;
  (void)device;
}

RETRO_API void retro_reset(void) { frame = 0; }

RETRO_API void retro_run(void) {
  input_poll_cb();
  if (!resources || vulkan == NULL) {
    video_cb(NULL, WIDTH, HEIGHT, 0);
    return;
  }
  vulkan->wait_sync_index(vulkan->handle);
  VkCommandBuffer command = commands[vulkan->get_sync_index(vulkan->handle) % COMMAND_BUFFERS];
  reset_command_buffer(command, 0);
  VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
  };
  begin_command_buffer(command, &begin);
  barrier(command, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
          VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT);
  float shade = (float)(frame % 60) / 60.0f;
  VkClearColorValue colour = {.float32 = {shade, 0.25f, 1.0f - shade, 1.0f}};
  VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  clear_color_image(command, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &colour, 1, &range);
  barrier(command, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
          VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_SHADER_READ_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
          VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT);
  end_command_buffer(command);
  vulkan->set_command_buffers(vulkan->handle, 1, &command);
  struct retro_vulkan_image presented = {
      .image_view = view,
      .image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
      .create_info = view_info,
  };
  vulkan->set_image(vulkan->handle, &presented, 0, NULL, VK_QUEUE_FAMILY_IGNORED);
  video_cb(RETRO_HW_FRAME_BUFFER_VALID, WIDTH, HEIGHT, 0);
  frame++;
}

RETRO_API size_t retro_serialize_size(void) { return 0; }
RETRO_API bool retro_serialize(void *data, size_t size) {
  (void)data;
  (void)size;
  return false;
}
RETRO_API bool retro_unserialize(const void *data, size_t size) {
  (void)data;
  (void)size;
  return false;
}
RETRO_API void retro_cheat_reset(void) {}
RETRO_API void retro_cheat_set(unsigned index, bool enabled, const char *code) {
  (void)index;
  (void)enabled;
  (void)code;
}

RETRO_API bool retro_load_game(const struct retro_game_info *game) {
  if (game == NULL) return false;
  enum retro_pixel_format format = RETRO_PIXEL_FORMAT_XRGB8888;
  environ_cb(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &format);
  memset(&hw, 0, sizeof(hw));
  hw.context_type = RETRO_HW_CONTEXT_VULKAN;
  hw.version_major = VK_API_VERSION_1_1;
  hw.context_reset = context_reset;
  hw.context_destroy = context_destroy;
  hw.cache_context = true;
  if (!environ_cb(RETRO_ENVIRONMENT_SET_HW_RENDER, &hw)) {
    note(RETRO_LOG_ERROR, "load_game: Vulkan context refused");
    return false;
  }
  static const struct retro_hw_render_context_negotiation_interface_vulkan negotiation = {
      RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN,
      RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION,
      application_info,
      create_device,
      NULL, /* destroy_device: the frontend owns the device, as with Azahar */
  };
  environ_cb(RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE, (void *)&negotiation);
  note(RETRO_LOG_INFO, "load_game: Vulkan context requested");
  return true;
}

RETRO_API bool retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t count) {
  (void)type;
  (void)info;
  (void)count;
  return false;
}

RETRO_API void retro_unload_game(void) {
  if (resources && vulkan != NULL) {
    /* Azahar's renderer destructor: the device as the frontend gives it now. */
    VkDevice device = vulkan->device;
    note(RETRO_LOG_INFO, "unload_game: waiting for the frontend's device");
    device_wait_idle(device);
    destroy_command_pool(device, pool, NULL);
    destroy_image_view(device, view, NULL);
    destroy_image(device, image, NULL);
    free_memory(device, memory, NULL);
    note(RETRO_LOG_INFO, "unload_game: resources destroyed through the frontend's device");
  }
  resources = false;
  vulkan = NULL;
}

RETRO_API unsigned retro_get_region(void) { return RETRO_REGION_NTSC; }
RETRO_API void *retro_get_memory_data(unsigned id) {
  (void)id;
  return NULL;
}
RETRO_API size_t retro_get_memory_size(unsigned id) {
  (void)id;
  return 0;
}
