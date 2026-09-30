#include <cassert>
#include <cstdint>
#include <cstdio>
#include <string_view>

namespace vk {
enum class driver_vendor { MVK, AMD, NVIDIA };
enum class chip_class { generic };
struct gpu_device {
    driver_vendor vendor;
    std::string_view get_name() const { return "fixture"; }
    driver_vendor get_driver_vendor() const { return vendor; }
    chip_class get_chip_class() const { return chip_class::generic; }
};
struct render_device {
    gpu_device value;
    bool conditional;
    const gpu_device& gpu() const { return value; }
    bool get_conditional_render_support() const { return conditional; }
};
const render_device* g_render_device;
driver_vendor g_driver_vendor = driver_vendor::AMD;
chip_class g_chip_class;
driver_vendor get_driver_vendor() { return g_driver_vendor; }
struct { void clear() {} } g_runtime_state;
bool g_drv_no_primitive_restart, g_drv_sanitize_fp_values, g_drv_disable_fence_reset;
bool g_drv_strict_query_scopes, g_drv_emulate_cond_render;
uint64_t g_num_processed_frames, g_num_total_frames, g_heap_compatible_buffer_types;
struct { struct { bool strict_rendering_mode = false, relaxed_zcull_sync = false; } video; } g_cfg;
void set_current_renderer(const render_device& device) {
#include "VKConditionalInitialization.inc"
    (void)gpu_name;
}
} // namespace vk

static bool backend_uses_gpu_predicate() {
#include "VKConditionalBackend.inc"
}

int main() {
    unsigned cases = 0;
    // Rebind repeatedly: the decision must use the new vendor, never stale
    // driver state from the previous renderer. MoltenVK stays CPU-resolved.
    for (auto vendor : {vk::driver_vendor::MVK, vk::driver_vendor::AMD, vk::driver_vendor::NVIDIA})
        for (bool native : {false, true})
            for (bool relaxed : {false, true})
                for (auto old_vendor : {vk::driver_vendor::MVK, vk::driver_vendor::AMD}) {
                    vk::g_driver_vendor = old_vendor;
                    vk::g_drv_emulate_cond_render = true;
                    vk::g_cfg.video.relaxed_zcull_sync = relaxed;
                    const vk::render_device device{{vendor}, native};
                    vk::set_current_renderer(device);
                    assert(vk::g_driver_vendor == vendor);
                    assert(vk::g_drv_emulate_cond_render ==
                           (vendor != vk::driver_vendor::MVK && relaxed && !native));
                    assert(backend_uses_gpu_predicate() == (vendor != vk::driver_vendor::MVK));
                    ++cases;
                }
    std::printf("Vulkan conditional rendering: %u renderer-rebind cases passed\n", cases);
}
