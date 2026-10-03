// SPDX-License-Identifier: MIT
#pragma once
#include "SourceClient.h"
#include <array>
#include <cstddef>
#include <cstdint>

namespace neostation::source_client {
// Immutable packed SOFTWARE pixels only, after the decoder has relinquished
// its references. Neither guest buffers nor GPU images belong to this client.
inline constexpr uint32_t frame_domain = 3;
inline constexpr uint64_t frame_max_bytes = 4ULL << 20;
inline constexpr uint32_t frame_max_chunks = 4;
inline constexpr uint64_t frame_cold_age_us = 250'000;
inline constexpr uint32_t frame_warm_count = 8, frame_min_queue = 24;
inline constexpr bool frame_requires_restore_slot(bool archived, bool has_output) noexcept {
    // Normal/warm/default-off consumption keeps the original producer wakeup.
    return archived && has_output;
}
inline bool frame_queue_has_room(uint64_t queued, uint64_t consuming, uint64_t maximum) noexcept {
    return queued < maximum && consuming < maximum - queued;
}
inline bool frame_can_cool(uint32_t queue, uint32_t position, uint64_t age_us,
                           uint64_t bytes, bool exclusively_owned) noexcept {
    return exclusively_owned && queue >= frame_min_queue && position < queue &&
        queue - position > frame_warm_count && age_us >= frame_cold_age_us &&
        bytes >= 4096 && bytes <= frame_max_bytes;
}
struct FrameReference final {
    std::array<Reference, frame_max_chunks> chunks;
    uint64_t bytes = 0;
    uint32_t count = 0;
};
class ColdFrame final {
public:
    bool archived() const noexcept { return bool(reference_); }
    void reset() noexcept { reference_.reset(); }
    // Transactional admission: every chunk shares ONE session; partial
    // acceptance is retired and the caller must keep its original AVFrame.
    // This only copies bounded bytes, never performs storage I/O.
    bool offload(const char* packed_pixels, size_t bytes) noexcept;
    // Allocation/copy lives in the dedicated exception-enabled source unit,
    // keeping decoder consumers valid with their real -fno-exceptions flags.
    using PixelCopy = int (*)(char*, size_t, void*);
    bool offload_copy(size_t bytes, PixelCopy copy, void* context) noexcept;
    // VDEC's CPU consumer only, outside the queue/conversion mutexes. Failed
    // restore clears output; no caller may consume partially restored pixels.
    int restore(std::string& output, int& os_error) const noexcept;
private:
    std::shared_ptr<FrameReference> reference_;
};
}
