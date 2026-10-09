#ifndef VK_USE_PLATFORM_METAL_EXT
#define VK_USE_PLATFORM_METAL_EXT 1
#endif
#ifndef VK_NO_PROTOTYPES
#define VK_NO_PROTOTYPES 1
#endif

#import "LibretroVulkanRenderer.h"

#include <vulkan/vulkan.h>

#include "libretro_vulkan.h"

#include <dlfcn.h>
#include <os/lock.h>
#include <pthread.h>
#include <string.h>

#define LIBRETRO_VK_MAX_IMAGES 8
#define LIBRETRO_VK_MAX_SEMAPHORES 16
#define LIBRETRO_VK_MAX_COMMANDS 16
#define LIBRETRO_VK_MAX_EXTENSIONS 32

static NSError *VulkanError(NSString *detail) {
  return [NSError errorWithDomain:@"org.neostation.libretro.vulkan"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : detail}];
}

static void *LoadMoltenVK(void) {
  static void *library = NULL;
  if (library != NULL) return library;
  NSString *frameworks = NSBundle.mainBundle.privateFrameworksPath ?: @"";
  NSString *path = [frameworks stringByAppendingPathComponent:@"MoltenVK.framework/MoltenVK"];
  // Process lifetime: MoltenVK registers Objective-C classes and must not be unloaded.
  library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
  return library;
}

static BOOL ContainsName(const char *const *names, uint32_t count, const char *name) {
  for (uint32_t index = 0; index < count; index++) {
    if (names[index] != NULL && strcmp(names[index], name) == 0) return YES;
  }
  return NO;
}

@implementation LibretroVulkanRenderer {
  CAMetalLayer *_layer;
  const struct retro_hw_render_context_negotiation_interface_vulkan *_negotiation;
  BOOL _negotiatedDevice;

  PFN_vkGetInstanceProcAddr _getInstanceProcAddr;
  PFN_vkGetDeviceProcAddr _getDeviceProcAddr;
  PFN_vkCreateInstance _createInstance;
  PFN_vkEnumerateInstanceExtensionProperties _enumerateInstanceExtensions;
  PFN_vkDestroyInstance _destroyInstance;
  PFN_vkEnumeratePhysicalDevices _enumeratePhysicalDevices;
  PFN_vkGetPhysicalDeviceQueueFamilyProperties _getQueueFamilies;
  PFN_vkGetPhysicalDeviceSurfaceSupportKHR _getSurfaceSupport;
  PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR _getSurfaceCapabilities;
  PFN_vkGetPhysicalDeviceSurfaceFormatsKHR _getSurfaceFormats;
  PFN_vkEnumerateDeviceExtensionProperties _enumerateDeviceExtensions;
  PFN_vkCreateMetalSurfaceEXT _createMetalSurface;
  PFN_vkDestroySurfaceKHR _destroySurface;
  PFN_vkCreateDevice _createDevice;

  PFN_vkDestroyDevice _destroyDevice;
  PFN_vkGetDeviceQueue _getDeviceQueue;
  PFN_vkDeviceWaitIdle _deviceWaitIdle;
  PFN_vkCreateSwapchainKHR _createSwapchain;
  PFN_vkDestroySwapchainKHR _destroySwapchain;
  PFN_vkGetSwapchainImagesKHR _getSwapchainImages;
  PFN_vkAcquireNextImageKHR _acquireNextImage;
  PFN_vkQueuePresentKHR _queuePresent;
  PFN_vkCreateCommandPool _createCommandPool;
  PFN_vkDestroyCommandPool _destroyCommandPool;
  PFN_vkAllocateCommandBuffers _allocateCommandBuffers;
  PFN_vkResetCommandBuffer _resetCommandBuffer;
  PFN_vkBeginCommandBuffer _beginCommandBuffer;
  PFN_vkEndCommandBuffer _endCommandBuffer;
  PFN_vkCmdPipelineBarrier _cmdPipelineBarrier;
  PFN_vkCmdBlitImage _cmdBlitImage;
  PFN_vkCmdClearColorImage _cmdClearColorImage;
  PFN_vkQueueSubmit _queueSubmit;
  PFN_vkCreateFence _createFence;
  PFN_vkDestroyFence _destroyFence;
  PFN_vkWaitForFences _waitForFences;
  PFN_vkResetFences _resetFences;
  PFN_vkCreateSemaphore _createSemaphore;
  PFN_vkDestroySemaphore _destroySemaphore;

  VkInstance _instance;
  VkPhysicalDevice _gpu;
  VkDevice _device;
  VkQueue _queue;
  uint32_t _queueFamily;
  VkSurfaceKHR _surface;
  BOOL _portabilityEnumeration;
  BOOL _portabilitySubset;

  VkSwapchainKHR _swapchain;
  VkFormat _swapchainFormat;
  VkExtent2D _extent;
  uint32_t _imageCount;
  VkImage _images[LIBRETRO_VK_MAX_IMAGES];
  VkCommandPool _commandPool;
  VkCommandBuffer _commandBuffers[LIBRETRO_VK_MAX_IMAGES];
  VkFence _fences[LIBRETRO_VK_MAX_IMAGES];
  BOOL _fenceSubmitted[LIBRETRO_VK_MAX_IMAGES];
  VkSemaphore _acquireSemaphores[LIBRETRO_VK_MAX_IMAGES];
  BOOL _acquireSlotUsed[LIBRETRO_VK_MAX_IMAGES];
  uint32_t _acquireSlotImage[LIBRETRO_VK_MAX_IMAGES];
  uint32_t _acquireSlot;
  uint32_t _currentAcquireSlot;
  VkSemaphore _renderSemaphores[LIBRETRO_VK_MAX_IMAGES];
  uint32_t _currentIndex;
  BOOL _acquired;
  BOOL _needsRecreate;

  struct retro_vulkan_image _lastImage;
  BOOL _hasLastImage;
  unsigned _lastWidth;
  unsigned _lastHeight;
  uint32_t _imageSourceQueueFamily;
  VkSemaphore _pendingWait[LIBRETRO_VK_MAX_SEMAPHORES];
  uint32_t _pendingWaitCount;
  VkCommandBuffer _coreCommands[LIBRETRO_VK_MAX_COMMANDS];
  uint32_t _coreCommandCount;
  VkSemaphore _signalSemaphore;

  pthread_mutex_t _queueLock;
  struct retro_hw_render_interface_vulkan _interface;
  os_unfair_lock _rectLock;
  CGRect _videoRect;
}

#pragma mark - Render interface callbacks

static void LibretroVkSetImage(void *handle, const struct retro_vulkan_image *image, uint32_t semaphoreCount,
                               const VkSemaphore *semaphores, uint32_t sourceQueueFamily) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer == nil) return;
  if (image != NULL) {
    renderer->_lastImage = *image;
    renderer->_lastImage.create_info.pNext = NULL;
    renderer->_hasLastImage = YES;
  }
  renderer->_imageSourceQueueFamily = sourceQueueFamily;
  renderer->_pendingWaitCount = 0;
  for (uint32_t index = 0; index < semaphoreCount && index < LIBRETRO_VK_MAX_SEMAPHORES; index++) {
    renderer->_pendingWait[renderer->_pendingWaitCount++] = semaphores[index];
  }
}

static uint32_t LibretroVkGetSyncIndex(void *handle) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  return renderer != nil ? renderer->_currentIndex : 0;
}

static uint32_t LibretroVkGetSyncIndexMask(void *handle) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer == nil || renderer->_imageCount == 0) return 1;
  return renderer->_imageCount >= 32 ? 0xFFFFFFFFu : ((1u << renderer->_imageCount) - 1u);
}

static void LibretroVkSetCommandBuffers(void *handle, uint32_t count, const VkCommandBuffer *commands) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer == nil) return;
  for (uint32_t index = 0; index < count && renderer->_coreCommandCount < LIBRETRO_VK_MAX_COMMANDS; index++) {
    renderer->_coreCommands[renderer->_coreCommandCount++] = commands[index];
  }
}

static void LibretroVkWaitSyncIndex(void *handle) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer == nil || renderer->_device == VK_NULL_HANDLE) return;
  uint32_t index = renderer->_currentIndex;
  if (index < LIBRETRO_VK_MAX_IMAGES && renderer->_fenceSubmitted[index]) {
    renderer->_waitForFences(renderer->_device, 1, &renderer->_fences[index], VK_TRUE, UINT64_MAX);
  }
}

static void LibretroVkLockQueue(void *handle) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer != nil) pthread_mutex_lock(&renderer->_queueLock);
}

static void LibretroVkUnlockQueue(void *handle) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer != nil) pthread_mutex_unlock(&renderer->_queueLock);
}

static void LibretroVkSetSignalSemaphore(void *handle, VkSemaphore semaphore) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)handle;
  if (renderer != nil) renderer->_signalSemaphore = semaphore;
}

#pragma mark - Negotiation wrappers

static VkInstance LibretroVkCreateInstanceWrapper(void *opaque, const VkInstanceCreateInfo *createInfo) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)opaque;
  if (renderer == nil || createInfo == NULL) return VK_NULL_HANDLE;
  const char *extensions[LIBRETRO_VK_MAX_EXTENSIONS];
  uint32_t count = 0;
  for (uint32_t index = 0; index < createInfo->enabledExtensionCount && count < LIBRETRO_VK_MAX_EXTENSIONS - 4; index++) {
    extensions[count++] = createInfo->ppEnabledExtensionNames[index];
  }
  const char *required[3] = {VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME,
                             renderer->_portabilityEnumeration ? VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME : NULL};
  for (uint32_t index = 0; index < 3; index++) {
    if (required[index] != NULL && !ContainsName(extensions, count, required[index])) extensions[count++] = required[index];
  }
  VkInstanceCreateInfo info = *createInfo;
  info.enabledExtensionCount = count;
  info.ppEnabledExtensionNames = extensions;
  if (renderer->_portabilityEnumeration) info.flags |= VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
  VkInstance instance = VK_NULL_HANDLE;
  if (renderer->_createInstance(&info, NULL, &instance) != VK_SUCCESS) return VK_NULL_HANDLE;
  return instance;
}

static VkDevice LibretroVkCreateDeviceWrapper(VkPhysicalDevice gpu, void *opaque, const VkDeviceCreateInfo *createInfo) {
  LibretroVulkanRenderer *renderer = (__bridge LibretroVulkanRenderer *)opaque;
  if (renderer == nil || createInfo == NULL) return VK_NULL_HANDLE;
  const char *extensions[LIBRETRO_VK_MAX_EXTENSIONS];
  uint32_t count = 0;
  for (uint32_t index = 0; index < createInfo->enabledExtensionCount && count < LIBRETRO_VK_MAX_EXTENSIONS - 2; index++) {
    extensions[count++] = createInfo->ppEnabledExtensionNames[index];
  }
  if (!ContainsName(extensions, count, VK_KHR_SWAPCHAIN_EXTENSION_NAME)) extensions[count++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
  if (renderer->_portabilitySubset && !ContainsName(extensions, count, "VK_KHR_portability_subset")) {
    extensions[count++] = "VK_KHR_portability_subset";
  }
  VkDeviceCreateInfo info = *createInfo;
  info.enabledExtensionCount = count;
  info.ppEnabledExtensionNames = extensions;
  VkDevice device = VK_NULL_HANDLE;
  if (renderer->_createDevice(gpu, &info, NULL, &device) != VK_SUCCESS) return VK_NULL_HANDLE;
  return device;
}

#pragma mark - Lifecycle

+ (unsigned)negotiationVersionForType:(enum retro_hw_render_context_negotiation_interface_type)type {
  return type == RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN ? 2 : 0;
}

+ (nullable instancetype)rendererForCallback:(struct retro_hw_render_callback *)callback layer:(CAMetalLayer *)layer {
  if (callback->context_type != RETRO_HW_CONTEXT_VULKAN || LoadMoltenVK() == NULL) return nil;
  LibretroVulkanRenderer *renderer = [[self alloc] init];
  renderer->_layer = layer;
  // Vulkan cores obtain everything through GET_HW_RENDER_INTERFACE.
  callback->get_current_framebuffer = NULL;
  callback->get_proc_address = NULL;
  return renderer;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    pthread_mutex_init(&_queueLock, NULL);
    _rectLock = OS_UNFAIR_LOCK_INIT;
    _videoRect = CGRectMake(0, 0, 1, 1);
  }
  return self;
}

- (void)dealloc {
  [self teardown];
  pthread_mutex_destroy(&_queueLock);
}

- (BOOL)setNegotiationInterface:(const struct retro_hw_render_context_negotiation_interface *)negotiation {
  if (negotiation == NULL || negotiation->interface_type != RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN) {
    return NO;
  }
  _negotiation = (const struct retro_hw_render_context_negotiation_interface_vulkan *)negotiation;
  return YES;
}

- (CGRect)normalizedVideoRect {
  os_unfair_lock_lock(&_rectLock);
  CGRect rect = _videoRect;
  os_unfair_lock_unlock(&_rectLock);
  return rect;
}

- (const struct retro_hw_render_interface *)renderInterface {
  return _device != VK_NULL_HANDLE ? (const struct retro_hw_render_interface *)&_interface : NULL;
}

#define LOAD_INSTANCE(target, name) target = (__typeof__(target))_getInstanceProcAddr(_instance, #name)
#define LOAD_DEVICE(target, name) target = (__typeof__(target))_getDeviceProcAddr(_device, #name)

- (BOOL)prepare:(NSError **)error {
  void *library = LoadMoltenVK();
  if (library == NULL) {
    if (error) *error = VulkanError(@"MoltenVK.framework missing");
    return NO;
  }
  _getInstanceProcAddr = (PFN_vkGetInstanceProcAddr)dlsym(library, "vkGetInstanceProcAddr");
  if (_getInstanceProcAddr == NULL) {
    if (error) *error = VulkanError(@"vkGetInstanceProcAddr missing");
    return NO;
  }
  _createInstance = (PFN_vkCreateInstance)_getInstanceProcAddr(VK_NULL_HANDLE, "vkCreateInstance");
  _enumerateInstanceExtensions = (PFN_vkEnumerateInstanceExtensionProperties)_getInstanceProcAddr(
      VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
  if (_createInstance == NULL || _enumerateInstanceExtensions == NULL) {
    if (error) *error = VulkanError(@"Vulkan global entry points missing");
    return NO;
  }
  uint32_t extensionCount = 0;
  _enumerateInstanceExtensions(NULL, &extensionCount, NULL);
  if (extensionCount > 0) {
    VkExtensionProperties *properties = calloc(extensionCount, sizeof(VkExtensionProperties));
    _enumerateInstanceExtensions(NULL, &extensionCount, properties);
    for (uint32_t index = 0; index < extensionCount; index++) {
      if (strcmp(properties[index].extensionName, VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME) == 0) {
        _portabilityEnumeration = YES;
      }
    }
    free(properties);
  }

  const VkApplicationInfo *application = NULL;
  if (_negotiation != NULL && _negotiation->get_application_info != NULL) {
    application = _negotiation->get_application_info();
  }
  VkApplicationInfo fallback = {
      .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
      .pApplicationName = "NeoStation",
      .applicationVersion = 1,
      .pEngineName = "NeoStation libretro",
      .engineVersion = 1,
      .apiVersion = VK_API_VERSION_1_1,
  };
  if (application == NULL) application = &fallback;

  if (_negotiation != NULL && _negotiation->interface_version >= 2 && _negotiation->create_instance != NULL) {
    _instance = _negotiation->create_instance(_getInstanceProcAddr, application, LibretroVkCreateInstanceWrapper,
                                              (__bridge void *)self);
  } else {
    VkInstanceCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = application,
    };
    _instance = LibretroVkCreateInstanceWrapper((__bridge void *)self, &info);
  }
  if (_instance == VK_NULL_HANDLE) {
    if (error) *error = VulkanError(@"vkCreateInstance failed");
    return NO;
  }
  LOAD_INSTANCE(_destroyInstance, vkDestroyInstance);
  LOAD_INSTANCE(_enumeratePhysicalDevices, vkEnumeratePhysicalDevices);
  LOAD_INSTANCE(_getQueueFamilies, vkGetPhysicalDeviceQueueFamilyProperties);
  LOAD_INSTANCE(_getSurfaceSupport, vkGetPhysicalDeviceSurfaceSupportKHR);
  LOAD_INSTANCE(_getSurfaceCapabilities, vkGetPhysicalDeviceSurfaceCapabilitiesKHR);
  LOAD_INSTANCE(_getSurfaceFormats, vkGetPhysicalDeviceSurfaceFormatsKHR);
  LOAD_INSTANCE(_enumerateDeviceExtensions, vkEnumerateDeviceExtensionProperties);
  LOAD_INSTANCE(_createMetalSurface, vkCreateMetalSurfaceEXT);
  LOAD_INSTANCE(_destroySurface, vkDestroySurfaceKHR);
  LOAD_INSTANCE(_createDevice, vkCreateDevice);
  LOAD_INSTANCE(_getDeviceProcAddr, vkGetDeviceProcAddr);
  if (_enumeratePhysicalDevices == NULL || _createMetalSurface == NULL || _createDevice == NULL ||
      _getDeviceProcAddr == NULL) {
    if (error) *error = VulkanError(@"Vulkan instance entry points missing");
    return NO;
  }

  VkMetalSurfaceCreateInfoEXT surfaceInfo = {
      .sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT,
      .pLayer = _layer,
  };
  if (_createMetalSurface(_instance, &surfaceInfo, NULL, &_surface) != VK_SUCCESS) {
    if (error) *error = VulkanError(@"vkCreateMetalSurfaceEXT failed");
    return NO;
  }

  uint32_t gpuCount = 1;
  VkPhysicalDevice gpu = VK_NULL_HANDLE;
  VkResult enumerated = _enumeratePhysicalDevices(_instance, &gpuCount, &gpu);
  if ((enumerated != VK_SUCCESS && enumerated != VK_INCOMPLETE) || gpu == VK_NULL_HANDLE) {
    if (error) *error = VulkanError(@"no Vulkan physical device");
    return NO;
  }
  _gpu = gpu;
  uint32_t deviceExtensionCount = 0;
  _enumerateDeviceExtensions(_gpu, NULL, &deviceExtensionCount, NULL);
  if (deviceExtensionCount > 0) {
    VkExtensionProperties *properties = calloc(deviceExtensionCount, sizeof(VkExtensionProperties));
    _enumerateDeviceExtensions(_gpu, NULL, &deviceExtensionCount, properties);
    for (uint32_t index = 0; index < deviceExtensionCount; index++) {
      if (strcmp(properties[index].extensionName, "VK_KHR_portability_subset") == 0) _portabilitySubset = YES;
    }
    free(properties);
  }

  struct retro_vulkan_context context;
  memset(&context, 0, sizeof(context));
  BOOL created = NO;
  if (_negotiation != NULL && _negotiation->interface_version >= 2 && _negotiation->create_device2 != NULL) {
    created = _negotiation->create_device2(&context, _instance, _gpu, _surface, _getInstanceProcAddr,
                                           LibretroVkCreateDeviceWrapper, (__bridge void *)self);
    if (!created) {
      memset(&context, 0, sizeof(context));
      created = _negotiation->create_device2(&context, _instance, VK_NULL_HANDLE, _surface, _getInstanceProcAddr,
                                             LibretroVkCreateDeviceWrapper, (__bridge void *)self);
    }
  } else if (_negotiation != NULL && _negotiation->create_device != NULL) {
    const char *extensions[2] = {VK_KHR_SWAPCHAIN_EXTENSION_NAME, "VK_KHR_portability_subset"};
    VkPhysicalDeviceFeatures features;
    memset(&features, 0, sizeof(features));
    created = _negotiation->create_device(&context, _instance, _gpu, _surface, _getInstanceProcAddr, extensions,
                                          _portabilitySubset ? 2 : 1, NULL, 0, &features);
  }
  if (created && context.device != VK_NULL_HANDLE) {
    _negotiatedDevice = YES;
    _gpu = context.gpu != VK_NULL_HANDLE ? context.gpu : _gpu;
    _device = context.device;
    _queue = context.queue;
    _queueFamily = context.queue_family_index;
  } else if (![self createDefaultDevice:error]) {
    return NO;
  }
  LOAD_DEVICE(_destroyDevice, vkDestroyDevice);
  LOAD_DEVICE(_getDeviceQueue, vkGetDeviceQueue);
  LOAD_DEVICE(_deviceWaitIdle, vkDeviceWaitIdle);
  LOAD_DEVICE(_createSwapchain, vkCreateSwapchainKHR);
  LOAD_DEVICE(_destroySwapchain, vkDestroySwapchainKHR);
  LOAD_DEVICE(_getSwapchainImages, vkGetSwapchainImagesKHR);
  LOAD_DEVICE(_acquireNextImage, vkAcquireNextImageKHR);
  LOAD_DEVICE(_queuePresent, vkQueuePresentKHR);
  LOAD_DEVICE(_createCommandPool, vkCreateCommandPool);
  LOAD_DEVICE(_destroyCommandPool, vkDestroyCommandPool);
  LOAD_DEVICE(_allocateCommandBuffers, vkAllocateCommandBuffers);
  LOAD_DEVICE(_resetCommandBuffer, vkResetCommandBuffer);
  LOAD_DEVICE(_beginCommandBuffer, vkBeginCommandBuffer);
  LOAD_DEVICE(_endCommandBuffer, vkEndCommandBuffer);
  LOAD_DEVICE(_cmdPipelineBarrier, vkCmdPipelineBarrier);
  LOAD_DEVICE(_cmdBlitImage, vkCmdBlitImage);
  LOAD_DEVICE(_cmdClearColorImage, vkCmdClearColorImage);
  LOAD_DEVICE(_queueSubmit, vkQueueSubmit);
  LOAD_DEVICE(_createFence, vkCreateFence);
  LOAD_DEVICE(_destroyFence, vkDestroyFence);
  LOAD_DEVICE(_waitForFences, vkWaitForFences);
  LOAD_DEVICE(_resetFences, vkResetFences);
  LOAD_DEVICE(_createSemaphore, vkCreateSemaphore);
  LOAD_DEVICE(_destroySemaphore, vkDestroySemaphore);
  if (_createSwapchain == NULL || _queueSubmit == NULL || _cmdBlitImage == NULL || _acquireNextImage == NULL) {
    if (error) *error = VulkanError(@"Vulkan device entry points missing");
    return NO;
  }
  if (_queue == VK_NULL_HANDLE) _getDeviceQueue(_device, _queueFamily, 0, &_queue);

  VkCommandPoolCreateInfo poolInfo = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
      .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
      .queueFamilyIndex = _queueFamily,
  };
  if (_createCommandPool(_device, &poolInfo, NULL, &_commandPool) != VK_SUCCESS) {
    if (error) *error = VulkanError(@"vkCreateCommandPool failed");
    return NO;
  }
  if (![self createSwapchain:error]) return NO;

  memset(&_interface, 0, sizeof(_interface));
  _interface.interface_type = RETRO_HW_RENDER_INTERFACE_VULKAN;
  _interface.interface_version = RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION;
  _interface.handle = (__bridge void *)self;
  _interface.instance = _instance;
  _interface.gpu = _gpu;
  _interface.device = _device;
  _interface.get_device_proc_addr = _getDeviceProcAddr;
  _interface.get_instance_proc_addr = _getInstanceProcAddr;
  _interface.queue = _queue;
  _interface.queue_index = _queueFamily;
  _interface.set_image = LibretroVkSetImage;
  _interface.get_sync_index = LibretroVkGetSyncIndex;
  _interface.get_sync_index_mask = LibretroVkGetSyncIndexMask;
  _interface.set_command_buffers = LibretroVkSetCommandBuffers;
  _interface.wait_sync_index = LibretroVkWaitSyncIndex;
  _interface.lock_queue = LibretroVkLockQueue;
  _interface.unlock_queue = LibretroVkUnlockQueue;
  _interface.set_signal_semaphore = LibretroVkSetSignalSemaphore;
  return YES;
}

- (BOOL)createDefaultDevice:(NSError **)error {
  uint32_t familyCount = 0;
  _getQueueFamilies(_gpu, &familyCount, NULL);
  if (familyCount == 0) {
    if (error) *error = VulkanError(@"no Vulkan queue family");
    return NO;
  }
  VkQueueFamilyProperties *families = calloc(familyCount, sizeof(VkQueueFamilyProperties));
  _getQueueFamilies(_gpu, &familyCount, families);
  BOOL found = NO;
  for (uint32_t index = 0; index < familyCount && !found; index++) {
    VkBool32 present = VK_FALSE;
    if (_getSurfaceSupport != NULL) _getSurfaceSupport(_gpu, index, _surface, &present);
    VkQueueFlags required = VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT;
    if ((families[index].queueFlags & required) == required && present) {
      _queueFamily = index;
      found = YES;
    }
  }
  free(families);
  if (!found) {
    if (error) *error = VulkanError(@"no graphics and present queue");
    return NO;
  }
  float priority = 1.0f;
  VkDeviceQueueCreateInfo queueInfo = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
      .queueFamilyIndex = _queueFamily,
      .queueCount = 1,
      .pQueuePriorities = &priority,
  };
  VkDeviceCreateInfo deviceInfo = {
      .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
      .queueCreateInfoCount = 1,
      .pQueueCreateInfos = &queueInfo,
  };
  _device = LibretroVkCreateDeviceWrapper(_gpu, (__bridge void *)self, &deviceInfo);
  if (_device == VK_NULL_HANDLE) {
    if (error) *error = VulkanError(@"vkCreateDevice failed");
    return NO;
  }
  return YES;
}

- (BOOL)createSwapchain:(NSError **)error {
  VkSurfaceCapabilitiesKHR capabilities;
  memset(&capabilities, 0, sizeof(capabilities));
  if (_getSurfaceCapabilities(_gpu, _surface, &capabilities) != VK_SUCCESS) {
    if (error) *error = VulkanError(@"surface capabilities unavailable");
    return NO;
  }
  VkExtent2D extent = capabilities.currentExtent;
  if (extent.width == UINT32_MAX || extent.width == 0 || extent.height == 0) {
    CGSize size = _layer.drawableSize;
    extent.width = (uint32_t)MAX(size.width, 1.0);
    extent.height = (uint32_t)MAX(size.height, 1.0);
  }
  uint32_t imageCount = MAX(3u, capabilities.minImageCount);
  if (capabilities.maxImageCount > 0 && imageCount > capabilities.maxImageCount) imageCount = capabilities.maxImageCount;
  if (imageCount > LIBRETRO_VK_MAX_IMAGES) imageCount = LIBRETRO_VK_MAX_IMAGES;

  uint32_t formatCount = 0;
  _getSurfaceFormats(_gpu, _surface, &formatCount, NULL);
  VkSurfaceFormatKHR chosen = {VK_FORMAT_B8G8R8A8_UNORM, VK_COLOR_SPACE_SRGB_NONLINEAR_KHR};
  if (formatCount > 0) {
    VkSurfaceFormatKHR *formats = calloc(formatCount, sizeof(VkSurfaceFormatKHR));
    _getSurfaceFormats(_gpu, _surface, &formatCount, formats);
    chosen = formats[0];
    for (uint32_t index = 0; index < formatCount; index++) {
      if (formats[index].format == VK_FORMAT_B8G8R8A8_UNORM) {
        chosen = formats[index];
        break;
      }
    }
    free(formats);
  }
  VkCompositeAlphaFlagBitsKHR alpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
  if ((capabilities.supportedCompositeAlpha & alpha) == 0) {
    for (uint32_t bit = 1; bit != 0 && bit <= capabilities.supportedCompositeAlpha; bit <<= 1) {
      if (capabilities.supportedCompositeAlpha & bit) {
        alpha = (VkCompositeAlphaFlagBitsKHR)bit;
        break;
      }
    }
  }
  VkSwapchainKHR old = _swapchain;
  VkSwapchainCreateInfoKHR info = {
      .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
      .surface = _surface,
      .minImageCount = imageCount,
      .imageFormat = chosen.format,
      .imageColorSpace = chosen.colorSpace,
      .imageExtent = extent,
      .imageArrayLayers = 1,
      .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
      .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
      .preTransform = capabilities.currentTransform,
      .compositeAlpha = alpha,
      .presentMode = VK_PRESENT_MODE_FIFO_KHR,
      .clipped = VK_TRUE,
      .oldSwapchain = old,
  };
  VkSwapchainKHR swapchain = VK_NULL_HANDLE;
  if (_createSwapchain(_device, &info, NULL, &swapchain) != VK_SUCCESS) {
    if (error) *error = VulkanError(@"vkCreateSwapchainKHR failed");
    return NO;
  }
  [self destroySwapchainResources];
  if (old != VK_NULL_HANDLE) _destroySwapchain(_device, old, NULL);
  _swapchain = swapchain;
  _swapchainFormat = chosen.format;
  _extent = extent;
  uint32_t count = 0;
  _getSwapchainImages(_device, _swapchain, &count, NULL);
  if (count > LIBRETRO_VK_MAX_IMAGES) count = LIBRETRO_VK_MAX_IMAGES;
  _getSwapchainImages(_device, _swapchain, &count, _images);
  _imageCount = count;
  VkCommandBufferAllocateInfo allocation = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
      .commandPool = _commandPool,
      .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
      .commandBufferCount = count,
  };
  if (_allocateCommandBuffers(_device, &allocation, _commandBuffers) != VK_SUCCESS) {
    if (error) *error = VulkanError(@"vkAllocateCommandBuffers failed");
    return NO;
  }
  VkFenceCreateInfo fenceInfo = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO};
  VkSemaphoreCreateInfo semaphoreInfo = {.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  for (uint32_t index = 0; index < count; index++) {
    _createFence(_device, &fenceInfo, NULL, &_fences[index]);
    _createSemaphore(_device, &semaphoreInfo, NULL, &_acquireSemaphores[index]);
    _createSemaphore(_device, &semaphoreInfo, NULL, &_renderSemaphores[index]);
    _fenceSubmitted[index] = NO;
    _acquireSlotUsed[index] = NO;
  }
  _acquireSlot = 0;
  _needsRecreate = NO;
  return YES;
}

- (void)destroySwapchainResources {
  if (_device == VK_NULL_HANDLE) return;
  for (uint32_t index = 0; index < _imageCount; index++) {
    if (_fenceSubmitted[index]) _waitForFences(_device, 1, &_fences[index], VK_TRUE, UINT64_MAX);
    if (_fences[index] != VK_NULL_HANDLE) _destroyFence(_device, _fences[index], NULL);
    if (_acquireSemaphores[index] != VK_NULL_HANDLE) _destroySemaphore(_device, _acquireSemaphores[index], NULL);
    if (_renderSemaphores[index] != VK_NULL_HANDLE) _destroySemaphore(_device, _renderSemaphores[index], NULL);
    _fences[index] = VK_NULL_HANDLE;
    _acquireSemaphores[index] = VK_NULL_HANDLE;
    _renderSemaphores[index] = VK_NULL_HANDLE;
    _fenceSubmitted[index] = NO;
  }
  if (_imageCount > 0 && _commandPool != VK_NULL_HANDLE) {
    PFN_vkFreeCommandBuffers freeCommandBuffers =
        (PFN_vkFreeCommandBuffers)_getDeviceProcAddr(_device, "vkFreeCommandBuffers");
    if (freeCommandBuffers != NULL) freeCommandBuffers(_device, _commandPool, _imageCount, _commandBuffers);
  }
  _imageCount = 0;
}

#pragma mark - Frames

- (void)beginFrame {
  _acquired = NO;
  _coreCommandCount = 0;
  _signalSemaphore = VK_NULL_HANDLE;
  if (_device == VK_NULL_HANDLE || _swapchain == VK_NULL_HANDLE) return;
  if (_needsRecreate) {
    _deviceWaitIdle(_device);
    if (![self createSwapchain:nil]) return;
  }
  if (_imageCount == 0) return;
  uint32_t slot = _acquireSlot;
  _acquireSlot = (_acquireSlot + 1) % _imageCount;
  if (_acquireSlotUsed[slot]) {
    uint32_t previous = _acquireSlotImage[slot];
    if (_fenceSubmitted[previous]) _waitForFences(_device, 1, &_fences[previous], VK_TRUE, UINT64_MAX);
  }
  uint32_t index = 0;
  VkResult result =
      _acquireNextImage(_device, _swapchain, UINT64_MAX, _acquireSemaphores[slot], VK_NULL_HANDLE, &index);
  if (result == VK_ERROR_OUT_OF_DATE_KHR) {
    _needsRecreate = YES;
    return;
  }
  if (result != VK_SUCCESS && result != VK_SUBOPTIMAL_KHR) return;
  if (result == VK_SUBOPTIMAL_KHR) _needsRecreate = YES;
  if (_fenceSubmitted[index]) {
    _waitForFences(_device, 1, &_fences[index], VK_TRUE, UINT64_MAX);
    _fenceSubmitted[index] = NO;
  }
  _resetFences(_device, 1, &_fences[index]);
  _acquireSlotUsed[slot] = YES;
  _acquireSlotImage[slot] = index;
  _currentAcquireSlot = slot;
  _currentIndex = index;
  _acquired = YES;
}

static void ImageBarrier(LibretroVulkanRenderer *renderer, VkCommandBuffer command, VkImage image,
                         VkImageSubresourceRange range, VkImageLayout from, VkImageLayout to, VkAccessFlags srcAccess,
                         VkAccessFlags dstAccess, VkPipelineStageFlags srcStage, VkPipelineStageFlags dstStage,
                         uint32_t srcFamily, uint32_t dstFamily) {
  VkImageMemoryBarrier barrier = {
      .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
      .srcAccessMask = srcAccess,
      .dstAccessMask = dstAccess,
      .oldLayout = from,
      .newLayout = to,
      .srcQueueFamilyIndex = srcFamily,
      .dstQueueFamilyIndex = dstFamily,
      .image = image,
      .subresourceRange = range,
  };
  renderer->_cmdPipelineBarrier(command, srcStage, dstStage, 0, 0, NULL, 0, NULL, 1, &barrier);
}

- (void)endFrameWithWidth:(unsigned)width height:(unsigned)height valid:(BOOL)valid {
  if (!_acquired) return;
  uint32_t index = _currentIndex;
  VkCommandBuffer command = _commandBuffers[index];
  _resetCommandBuffer(command, 0);
  VkCommandBufferBeginInfo begin = {
      .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
      .flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
  };
  _beginCommandBuffer(command, &begin);
  VkImageSubresourceRange swapRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
  ImageBarrier(self, command, _images[index], swapRange, VK_IMAGE_LAYOUT_UNDEFINED,
               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 0, VK_ACCESS_TRANSFER_WRITE_BIT,
               VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_QUEUE_FAMILY_IGNORED,
               VK_QUEUE_FAMILY_IGNORED);
  VkClearColorValue black = {.float32 = {0.0f, 0.0f, 0.0f, 1.0f}};
  _cmdClearColorImage(command, _images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &black, 1, &swapRange);
  ImageBarrier(self, command, _images[index], swapRange, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK_ACCESS_TRANSFER_WRITE_BIT, VK_ACCESS_TRANSFER_WRITE_BIT,
               VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_QUEUE_FAMILY_IGNORED,
               VK_QUEUE_FAMILY_IGNORED);

  if (width > 0 && height > 0) {
    _lastWidth = width;
    _lastHeight = height;
  }
  if (_hasLastImage && _lastWidth > 0 && _lastHeight > 0) {
    VkImage source = _lastImage.create_info.image;
    VkImageSubresourceRange range = _lastImage.create_info.subresourceRange;
    range.levelCount = 1;
    range.layerCount = 1;
    VkImageLayout layout = _lastImage.image_layout;
    BOOL general = layout == VK_IMAGE_LAYOUT_GENERAL;
    uint32_t sourceFamily = _imageSourceQueueFamily;
    BOOL transfer = sourceFamily != VK_QUEUE_FAMILY_IGNORED && sourceFamily != _queueFamily;
    VkImageLayout blitLayout = general ? VK_IMAGE_LAYOUT_GENERAL : VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    if (!general || transfer) {
      ImageBarrier(self, command, source, range, layout, blitLayout,
                   VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT | VK_ACCESS_SHADER_WRITE_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
                   VK_ACCESS_TRANSFER_READ_BIT, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                   transfer ? sourceFamily : VK_QUEUE_FAMILY_IGNORED, transfer ? _queueFamily : VK_QUEUE_FAMILY_IGNORED);
    }
    double aspect = self.aspectRatio > 0 ? self.aspectRatio : (double)_lastWidth / (double)_lastHeight;
    double videoWidth = (double)_extent.width;
    double videoHeight = videoWidth / aspect;
    if (videoHeight > (double)_extent.height) {
      videoHeight = (double)_extent.height;
      videoWidth = videoHeight * aspect;
    }
    int32_t x0 = (int32_t)(((double)_extent.width - videoWidth) / 2.0);
    int32_t y0 = (int32_t)(((double)_extent.height - videoHeight) / 2.0);
    os_unfair_lock_lock(&_rectLock);
    _videoRect = CGRectMake((double)x0 / _extent.width, (double)y0 / _extent.height, videoWidth / _extent.width,
                            videoHeight / _extent.height);
    os_unfair_lock_unlock(&_rectLock);
    VkImageBlit blit = {
        .srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, range.baseMipLevel, range.baseArrayLayer, 1},
        .srcOffsets = {{0, 0, 0}, {(int32_t)_lastWidth, (int32_t)_lastHeight, 1}},
        .dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1},
        .dstOffsets = {{x0, y0, 0}, {x0 + (int32_t)videoWidth, y0 + (int32_t)videoHeight, 1}},
    };
    _cmdBlitImage(command, source, blitLayout, _images[index], VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit,
                  self.smooth ? VK_FILTER_LINEAR : VK_FILTER_NEAREST);
    if (!general || transfer) {
      ImageBarrier(self, command, source, range, blitLayout, layout, VK_ACCESS_TRANSFER_READ_BIT,
                   VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                   VK_PIPELINE_STAGE_ALL_COMMANDS_BIT, transfer ? _queueFamily : VK_QUEUE_FAMILY_IGNORED,
                   transfer ? sourceFamily : VK_QUEUE_FAMILY_IGNORED);
    }
  }
  ImageBarrier(self, command, _images[index], swapRange, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
               VK_IMAGE_LAYOUT_PRESENT_SRC_KHR, VK_ACCESS_TRANSFER_WRITE_BIT, 0, VK_PIPELINE_STAGE_TRANSFER_BIT,
               VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, VK_QUEUE_FAMILY_IGNORED, VK_QUEUE_FAMILY_IGNORED);
  _endCommandBuffer(command);

  VkSemaphore waits[LIBRETRO_VK_MAX_SEMAPHORES + 1];
  VkPipelineStageFlags stages[LIBRETRO_VK_MAX_SEMAPHORES + 1];
  uint32_t waitCount = 0;
  waits[waitCount] = _acquireSemaphores[_currentAcquireSlot];
  stages[waitCount++] = VK_PIPELINE_STAGE_TRANSFER_BIT;
  if (valid && _coreCommandCount == 0) {
    for (uint32_t pending = 0; pending < _pendingWaitCount; pending++) {
      waits[waitCount] = _pendingWait[pending];
      stages[waitCount++] = VK_PIPELINE_STAGE_TRANSFER_BIT;
    }
  }
  _pendingWaitCount = 0;
  VkCommandBuffer commands[LIBRETRO_VK_MAX_COMMANDS + 1];
  uint32_t commandCount = 0;
  for (uint32_t core = 0; core < _coreCommandCount; core++) commands[commandCount++] = _coreCommands[core];
  commands[commandCount++] = command;
  VkSemaphore signals[2] = {_renderSemaphores[index], _signalSemaphore};
  VkSubmitInfo submit = {
      .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
      .waitSemaphoreCount = waitCount,
      .pWaitSemaphores = waits,
      .pWaitDstStageMask = stages,
      .commandBufferCount = commandCount,
      .pCommandBuffers = commands,
      .signalSemaphoreCount = _signalSemaphore != VK_NULL_HANDLE ? 2u : 1u,
      .pSignalSemaphores = signals,
  };
  pthread_mutex_lock(&_queueLock);
  VkResult submitted = _queueSubmit(_queue, 1, &submit, _fences[index]);
  if (submitted == VK_SUCCESS) {
    _fenceSubmitted[index] = YES;
    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &_renderSemaphores[index],
        .swapchainCount = 1,
        .pSwapchains = &_swapchain,
        .pImageIndices = &index,
    };
    VkResult presented = _queuePresent(_queue, &present);
    if (presented == VK_ERROR_OUT_OF_DATE_KHR || presented == VK_SUBOPTIMAL_KHR) _needsRecreate = YES;
  }
  pthread_mutex_unlock(&_queueLock);
  _coreCommandCount = 0;
  _signalSemaphore = VK_NULL_HANDLE;
  _acquired = NO;
}

- (void)waitIdle {
  if (_device != VK_NULL_HANDLE && _deviceWaitIdle != NULL) _deviceWaitIdle(_device);
}

- (void)teardown {
  if (_instance == VK_NULL_HANDLE) return;
  if (_device != VK_NULL_HANDLE) {
    if (_deviceWaitIdle != NULL) _deviceWaitIdle(_device);
    [self destroySwapchainResources];
    if (_swapchain != VK_NULL_HANDLE) _destroySwapchain(_device, _swapchain, NULL);
    _swapchain = VK_NULL_HANDLE;
    if (_commandPool != VK_NULL_HANDLE) _destroyCommandPool(_device, _commandPool, NULL);
    _commandPool = VK_NULL_HANDLE;
  }
  if (_negotiatedDevice && _negotiation != NULL && _negotiation->destroy_device != NULL) _negotiation->destroy_device();
  if (_device != VK_NULL_HANDLE && _destroyDevice != NULL) _destroyDevice(_device, NULL);
  _device = VK_NULL_HANDLE;
  if (_surface != VK_NULL_HANDLE && _destroySurface != NULL) _destroySurface(_instance, _surface, NULL);
  _surface = VK_NULL_HANDLE;
  if (_destroyInstance != NULL) _destroyInstance(_instance, NULL);
  _instance = VK_NULL_HANDLE;
  _hasLastImage = NO;
}

@end
