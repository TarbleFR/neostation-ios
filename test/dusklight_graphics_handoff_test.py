#!/usr/bin/env python3
"""Run the production buffer creation/drain/release/resume functions.

The fake driver keeps callback and bind-group references alive, models GPU
completion separately from the worker barrier, and injects delayed callbacks.
It verifies ownership/order, not Metal performance or iPhone VM placement.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
frame = (ROOT / 'native/dusklight/upstream/extern/aurora/lib/gfx/frame.cpp').read_text()

def function(signature, source=frame):
    start = source.index(signature)
    body = source.index('{', start)
    depth = 1
    end = body + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

prefix = r'''
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#define AURORA_ASSERT(condition, ...) assert(condition)
struct Logger { template<class... T> void warn(T...) {} } Log;
namespace magic_enum { template<class T> int enum_name(T value) { return int(value); } }
namespace fmt { std::string format(const char*, size_t) { return "Staging"; } }
struct Allocation { uint64_t size; bool destroyed = false; bool mapped = false; };
std::vector<std::shared_ptr<Allocation>> allocations;
uint64_t live_bytes() {
  uint64_t result = 0;
  for (const auto& a : allocations) if (!a->destroyed) result += a->size;
  return result;
}
bool gpuFinished = false, workerFinished = false;
int creations = 0, targetsReleased = 0, cacheClears = 0, recordingClears = 0;
uint64_t blockedFuture = 0;
bool failQueue = false, abortMap = false;
struct Pending { std::function<void()> callback; bool done = false; };
std::map<uint64_t, Pending> pending;
namespace wgpu {
enum class MapAsyncStatus { Success, CallbackCancelled, Aborted };
enum class QueueWorkDoneStatus { Success, Error };
enum class WaitStatus { Success, TimedOut };
enum class CallbackMode { AllowSpontaneous };
enum class MapMode { Write };
enum class BufferBindingType { ReadOnlyStorage, Uniform };
enum class ShaderStage { Vertex = 1, Fragment = 2 };
enum class BufferUsage { Uniform = 1, CopyDst = 2, Storage = 4, Vertex = 8, Index = 16, MapWrite = 32, CopySrc = 64 };
constexpr BufferUsage operator|(BufferUsage a, BufferUsage b) { return BufferUsage(int(a) | int(b)); }
constexpr ShaderStage operator|(ShaderStage a, ShaderStage b) { return ShaderStage(int(a) | int(b)); }
using StringView = const char*;
struct Future { uint64_t id = 0; };
Future defer(std::function<void()> callback) {
  const auto id = pending.size() + 1;
  pending.emplace(id, Pending{std::move(callback)});
  return {id};
}
struct BufferDescriptor { const char* label; BufferUsage usage; uint64_t size; };
struct Buffer {
  std::shared_ptr<Allocation> value;
  explicit operator bool() const { return bool(value); }
  template<class Fn> Future MapAsync(MapMode, uint64_t, uint64_t, CallbackMode, Fn callback) {
    auto keep = value;
    return defer([keep, callback] {
      assert(!keep->destroyed);
      keep->mapped = !abortMap;
      callback(abortMap ? MapAsyncStatus::Aborted : MapAsyncStatus::Success, "test");
    });
  }
  void Destroy() {
    assert(workerFinished && gpuFinished && value && !value->destroyed);
    for (const auto& [id, operation] : pending) assert(operation.done);
    value->destroyed = true;
    value->mapped = false;
  }
};
struct BufferBindingLayout { BufferBindingType type; bool hasDynamicOffset = false; };
struct BindGroupLayoutEntry { uint32_t binding; ShaderStage visibility; BufferBindingLayout buffer; };
struct BindGroupLayoutDescriptor { const char* label; size_t entryCount; const BindGroupLayoutEntry* entries; };
struct BindGroupLayout { int id = 0; explicit operator bool() const { return id != 0; } };
struct BindGroupEntry { uint32_t binding; Buffer buffer; uint64_t size = 0; };
struct BindGroupDescriptor { const char* label; BindGroupLayout layout; size_t entryCount; const BindGroupEntry* entries; };
struct BindGroup { std::vector<Buffer> references; };
struct Device {
  Buffer CreateBuffer(const BufferDescriptor* desc) {
    auto allocation = std::make_shared<Allocation>(Allocation{desc->size});
    allocations.push_back(allocation);
    ++creations;
    return {allocation};
  }
  BindGroupLayout CreateBindGroupLayout(const BindGroupLayoutDescriptor*) { static int next = 0; return {++next}; }
  BindGroup CreateBindGroup(const BindGroupDescriptor* desc) {
    BindGroup group;
    for (size_t i = 0; i < desc->entryCount; ++i) {
      assert(!desc->entries[i].buffer.value->destroyed);
      group.references.push_back(desc->entries[i].buffer);
    }
    return group;
  }
};
struct Queue {
  template<class Fn> Future OnSubmittedWorkDone(CallbackMode, Fn callback) {
    assert(workerFinished);
    return defer([callback] {
      gpuFinished = !failQueue;
      callback(failQueue ? QueueWorkDoneStatus::Error : QueueWorkDoneStatus::Success, "test");
    });
  }
};
struct Instance {
  WaitStatus WaitAny(Future future, uint64_t) {
    if (future.id == blockedFuture) return WaitStatus::TimedOut;
    auto& operation = pending.at(future.id);
    if (!operation.done) { operation.callback(); operation.done = true; }
    return WaitStatus::Success;
  }
};
}
namespace gx {
constexpr uint64_t MaxUniformSize = 1024;
void clear_copy_texture_cache() { assert(gpuFinished); }
}
namespace render_worker {
struct FrameSlotPool { int resets = 0, releases = 0; void reset() { ++resets; } void release(size_t) { ++releases; } };
void synchronize() { workerFinished = true; }
}
namespace webgpu {
struct Texture {
  std::shared_ptr<bool> destroyed;
  explicit operator bool() const { return bool(destroyed); }
  void Destroy() { assert(gpuFinished && !*destroyed); *destroyed = true; }
};
struct TextureWithSampler { Texture texture; };
TextureWithSampler g_frameBuffer, g_frameBufferResolved, g_depthBuffer, g_normalBuffer, g_resampledFrameBuffer;
wgpu::BindGroup g_CopyBindGroup;
void release_surface() { assert(gpuFinished && workerFinished); ++targetsReleased; }
void release_frame_targets();
}
constexpr uint64_t UniformBufferSize = 25165824, VertexBufferSize = 5242880,
    IndexBufferSize = 2097152, StorageBufferSize = 8388608, TextureUploadSize = 25165824;
constexpr size_t StagingBufferCount = 5, FrameSlotCount = 2;
constexpr uint64_t StagingBufferSize = UniformBufferSize + VertexBufferSize + IndexBufferSize + StorageBufferSize + TextureUploadSize;
constexpr uint64_t ExpectedBytes = 354ULL * 1024 * 1024;
struct Resources {
  wgpu::Buffer uniformBuffer, vertexBuffer, indexBuffer, storageBuffer;
  wgpu::BindGroupLayout staticBindGroupLayout, uniformBindGroupLayout;
  wgpu::BindGroup staticBindGroup, uniformBindGroup;
} g_resources;
wgpu::Device g_device;
wgpu::Queue g_queue;
wgpu::Instance g_instance;
enum class BufferMapState { Unmapped, Mapping, Mapped };
std::array<wgpu::Buffer, StagingBufferCount> g_stagingBuffers;
std::array<std::atomic<BufferMapState>, StagingBufferCount> g_mappingStates;
std::array<wgpu::Future, StagingBufferCount> g_mappingFutures;
std::array<int, FrameSlotCount> g_framePackets;
bool g_frameBuffersReleased = false;
uint32_t g_frameIndex = UINT32_MAX;
render_worker::FrameSlotPool g_frameSlots, g_stagingSlots;
using PresentClock = std::chrono::steady_clock;
int64_t duration_ns(PresentClock::duration time) { return std::chrono::duration_cast<std::chrono::nanoseconds>(time).count(); }
std::atomic_int64_t g_lastPresentNs = 0, g_presentPeriodNs = 0, g_cpuFrameTimeNs = 0;
PresentClock::time_point g_cpuFrameStart;
std::mutex g_presentStatsMutex;
std::vector<int> g_presentTimes;
void clear_caches() { assert(gpuFinished); ++cacheClears; }
void shutdown_recording() { assert(gpuFinished); ++recordingClears; }
'''

test = r'''
void finish_callbacks() {
  blockedFuture = 0;
  for (auto& [id, operation] : pending) g_instance.WaitAny({id}, 0);
}
int main() {
  assert(release_frame_resources()); // no GPU work before initialization
  assert(creations == 0 && targetsReleased == 0);
  g_frameIndex = 0;
  create_frame_buffers();
  const auto staticLayout = g_resources.staticBindGroupLayout.id;
  const auto uniformLayout = g_resources.uniformBindGroupLayout.id;
  assert(creations == 9 && live_bytes() == ExpectedBytes);
  // Delayed last mapping callback: CPU/GPU completion alone is insufficient.
  blockedFuture = g_mappingFutures.back().id;
  assert(!release_frame_resources());
  assert(live_bytes() == ExpectedBytes && targetsReleased == 0 && !g_frameBuffersReleased);
  assert(cacheClears == 0 && recordingClears == 0 && g_stagingSlots.resets == 0);
  finish_callbacks(); // callback may complete while another core is visible
  // GPU error: do not tear down resources on an unsuccessful fence.
  failQueue = true;
  assert(!release_frame_resources());
  assert(live_bytes() == ExpectedBytes && targetsReleased == 0);
  failQueue = false;
  // Pending queue completion itself can time out too.
  blockedFuture = pending.size() + 1;
  assert(!release_frame_resources());
  assert(live_bytes() == ExpectedBytes && targetsReleased == 0);
  finish_callbacks();
  for (int session = 0; session < 100; ++session) {
    workerFinished = gpuFinished = false;
    // Keep stale external references: Destroy must release storage even then.
    const auto oldBindings = g_resources.staticBindGroup;
    const auto oldStaging = g_stagingBuffers[0];
    std::vector<std::shared_ptr<bool>> frameTextures;
    for (auto* target : {&webgpu::g_frameBuffer, &webgpu::g_frameBufferResolved,
        &webgpu::g_depthBuffer, &webgpu::g_normalBuffer, &webgpu::g_resampledFrameBuffer}) {
      target->texture.destroyed = std::make_shared<bool>(false);
      frameTextures.push_back(target->texture.destroyed);
    }
    assert(release_frame_resources());
    for (const auto& destroyed : frameTextures) assert(*destroyed);
    assert(g_frameBuffersReleased && live_bytes() == 0);
    assert(oldStaging.value->destroyed);
    for (const auto& buffer : oldBindings.references) assert(buffer.value->destroyed);
    assert(targetsReleased == session + 1 && g_stagingSlots.resets == session + 1);
    auto count = pending.size();
    assert(release_frame_resources()); // repeated stop does nothing
    assert(pending.size() == count && targetsReleased == session + 1);
    resume_frame_resources();
    assert(!g_frameBuffersReleased && live_bytes() == ExpectedBytes);
    assert(g_resources.staticBindGroupLayout.id == staticLayout);
    assert(g_resources.uniformBindGroupLayout.id == uniformLayout);
    int previous = creations;
    resume_frame_resources(); // repeated resume does not allocate again
    assert(creations == previous && creations == 9 * (session + 2));
    abortMap = session % 2; // cancelled mapping callbacks still drain safely
    finish_callbacks();
    abortMap = false;
    assert(!g_stagingBuffers[0].value->destroyed);
  }
  assert(release_frame_resources() && live_bytes() == 0);
}
'''
gpu = (ROOT / 'native/dusklight/upstream/extern/aurora/lib/webgpu/gpu.cpp').read_text()
production = 'namespace webgpu {\n' + function('void release_frame_targets()', gpu) + '\n}\n'
production += '\n'.join(function(signature) for signature in (
    'void map_staging_buffer(', 'static void create_frame_buffers()',
    'bool release_frame_resources()', 'static void resume_frame_resources()'))
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / 'graphics.cpp'
    binary = Path(directory) / 'graphics-test'
    cpp.write_text(prefix + production + test)
    subprocess.run(['c++', '-std=c++20', '-pthread', '-Wall', '-Wextra', '-Werror',
                    str(cpp), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=15)

# The partial handoff remains independently safe, but ABI v4 deliberately uses
# the stronger terminal shutdown path instead of resuming this frame runtime.
core = (ROOT / 'native/dusklight/core/NeoDusklightCore.mm').read_text()
finish = core[core.index('void FinishReturn()'):core.index('void Stop()')]
assert finish.index('if (inNativeCall) return;') < finish.index('Suspend(true);')
assert 'NeoDusklight_ReleaseFrameResources()' not in finish
assert finish.index('RestoreHost();') < finish.index('NeoDusklight_ShutdownRuntime()') < finish.index('session.terminate();')
assert function('bool begin_frame()').index('resume_frame_resources();') < function('bool begin_frame()').index('acquire_frame_slot()')
print('PASS: partial GPU release stays safe while ABI v4 uses the terminal runtime shutdown barrier')
