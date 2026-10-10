// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <fcntl.h>
#include <sys/mman.h>
#include <unistd.h>

// NeoSwap cold-storage prefetch (Build434). Pure planning plus thin POSIX
// read-advice helpers, usable by the storage utility worker. No I/O happens
// in the planner, nothing here runs on a PPU/SPU/RSX thread, and nothing here
// maps or pages guest memory: the owned cold objects of the storage tier
// (compiled GLSL snapshots, archived VDEC pixels, managed CPU chunks) are the
// only consumers. A plan is a hint list; the worker still validates
// generation and checksum before publishing any restored chunk.
//
// Why a planner: the worker restores chunks on demand, so a scene transition
// pays one disk round trip per chunk it needs. Observing the access order of
// an object lets the worker issue F_RDADVISE for the next chunks of a
// sequential run while the current one is still being consumed, and warm the
// chunks that were hot recently. Under pressure every speculative entry is
// dropped: a prefetch must never compete with the data a consumer waits for.
namespace neostation::prefetch {
constexpr std::size_t maximum_tracked_objects = 32;
constexpr std::size_t maximum_plan_entries = 16;
// A chunk touched at least this many times in a row, in ascending order,
// is a sequential run: the planner then looks ahead by run_lookahead chunks.
constexpr std::uint32_t sequential_minimum = 2;
constexpr std::uint32_t run_lookahead = 4;
// Recent chunks stay candidates for this long after their last access.
constexpr std::uint64_t recency_window_ms = 2000;

enum class Priority : std::uint8_t { demanded = 0, sequential = 1, recent = 2 };
struct Entry {
    std::uint64_t object = 0;
    std::uint32_t chunk = 0;
    Priority priority = Priority::recent;
};
struct Plan {
    std::array<Entry, maximum_plan_entries> entries{};
    std::size_t count = 0;
    std::size_t cancelled_speculative = 0;
};
struct Stats {
    std::uint64_t observations = 0, demanded = 0, plans = 0, sequential_entries = 0, recent_entries = 0;
    std::uint64_t cancelled_speculative = 0, evicted_objects = 0;
};

class Planner final {
public:
    // Record an access. demanded = the consumer waits for this chunk now:
    // such a chunk always leads the next plan and survives pressure.
    void observe(std::uint64_t object, std::uint32_t chunk, std::uint32_t chunk_count,
                 std::uint64_t now_ms, bool demanded = false) noexcept {
        ++stats_.observations;
        if (demanded) ++stats_.demanded;
        Track* track = find(object);
        if (!track) track = adopt(object, now_ms);
        if (track->chunk_count != chunk_count) {
            // The object was recreated with another size: forget its history.
            track->chunk_count = chunk_count;
            track->run_length = 0;
            track->recent_count = 0;
        }
        if (track->run_length && chunk == track->last_chunk + 1) ++track->run_length;
        else track->run_length = 1;
        track->last_chunk = chunk;
        track->last_access_ms = now_ms;
        track->pending_demand = demanded;
        track->pending_demand_chunk = chunk;
        remember(*track, chunk, now_ms);
    }
    // Build a bounded plan: demanded chunks first, then the look-ahead of
    // sequential runs, then recently touched chunks of other objects, most
    // recent first. Under pressure only demanded chunks remain; the dropped
    // speculative entries are counted so the worker can report them.
    Plan plan(std::uint64_t now_ms, bool pressure, std::size_t limit = maximum_plan_entries) noexcept {
        Plan out{};
        ++stats_.plans;
        limit = std::min(limit, maximum_plan_entries);
        // Demanded entries never wait behind speculation.
        for (auto& track : tracks_) if (track.active && track.pending_demand && out.count < limit) {
            out.entries[out.count++] = {track.object, track.pending_demand_chunk, Priority::demanded};
            track.pending_demand = false;
        }
        std::size_t speculative = 0;
        // Sequential look-ahead, most recently active object first.
        for (std::size_t i = 0; i < tracks_.size(); ++i) {
            Track* track = most_recent(i);
            if (!track || track->run_length < sequential_minimum) continue;
            for (std::uint32_t ahead = 1; ahead <= run_lookahead; ++ahead) {
                const std::uint64_t next = std::uint64_t{track->last_chunk} + ahead;
                if (next >= track->chunk_count) break;
                ++speculative;
                if (pressure) continue;
                if (out.count < limit && !contains(out, track->object, static_cast<std::uint32_t>(next))) {
                    out.entries[out.count++] = {track->object, static_cast<std::uint32_t>(next), Priority::sequential};
                    ++stats_.sequential_entries;
                }
            }
        }
        // Recency: chunks touched within the window that are not already planned.
        for (std::size_t i = 0; i < tracks_.size(); ++i) {
            Track* track = most_recent(i);
            if (!track) continue;
            for (std::size_t r = 0; r < track->recent_count; ++r) {
                const auto& recent = track->recent[(track->recent_head + track->recent_capacity - 1 - r) % track->recent_capacity];
                if (now_ms - recent.at_ms > recency_window_ms) continue;
                if (recent.chunk == track->last_chunk) continue; // the consumer holds it already
                ++speculative;
                if (pressure) continue;
                if (out.count < limit && !contains(out, track->object, recent.chunk)) {
                    out.entries[out.count++] = {track->object, recent.chunk, Priority::recent};
                    ++stats_.recent_entries;
                }
            }
        }
        if (pressure) {
            out.cancelled_speculative = speculative;
            stats_.cancelled_speculative += speculative;
        }
        return out;
    }
    void forget(std::uint64_t object) noexcept {
        if (Track* track = find(object)) *track = Track{};
    }
    void reset() noexcept { for (auto& track : tracks_) track = Track{}; }
    Stats stats() const noexcept { return stats_; }
    std::size_t tracked() const noexcept {
        std::size_t n = 0;
        for (const auto& track : tracks_) n += track.active ? 1 : 0;
        return n;
    }
private:
    struct Recent { std::uint32_t chunk = 0; std::uint64_t at_ms = 0; };
    struct Track {
        static constexpr std::size_t recent_capacity = 8;
        bool active = false;
        std::uint64_t object = 0;
        std::uint32_t chunk_count = 0, last_chunk = 0, run_length = 0;
        std::uint64_t last_access_ms = 0;
        bool pending_demand = false;
        std::uint32_t pending_demand_chunk = 0;
        std::array<Recent, recent_capacity> recent{};
        std::size_t recent_head = 0, recent_count = 0;
    };
    std::array<Track, maximum_tracked_objects> tracks_{};
    Stats stats_{};
    Track* find(std::uint64_t object) noexcept {
        for (auto& track : tracks_) if (track.active && track.object == object) return &track;
        return nullptr;
    }
    Track* adopt(std::uint64_t object, std::uint64_t now_ms) noexcept {
        Track* victim = nullptr;
        for (auto& track : tracks_) {
            if (!track.active) { victim = &track; break; }
            if (!victim || track.last_access_ms < victim->last_access_ms) victim = &track;
        }
        if (victim->active) ++stats_.evicted_objects;
        *victim = Track{};
        victim->active = true;
        victim->object = object;
        victim->last_access_ms = now_ms;
        return victim;
    }
    static void remember(Track& track, std::uint32_t chunk, std::uint64_t now_ms) noexcept {
        for (std::size_t r = 0; r < track.recent_count; ++r) {
            auto& recent = track.recent[(track.recent_head + track.recent_capacity - 1 - r) % track.recent_capacity];
            if (recent.chunk == chunk) { recent.at_ms = now_ms; return; }
        }
        track.recent[track.recent_head] = {chunk, now_ms};
        track.recent_head = (track.recent_head + 1) % track.recent_capacity;
        track.recent_count = std::min(track.recent_count + 1, track.recent_capacity);
    }
    // The i-th most recently accessed active track (i = 0 is the latest).
    Track* most_recent(std::size_t rank) noexcept {
        std::array<Track*, maximum_tracked_objects> order{};
        std::size_t n = 0;
        for (auto& track : tracks_) if (track.active) order[n++] = &track;
        std::sort(order.begin(), order.begin() + static_cast<std::ptrdiff_t>(n),
                  [](const Track* a, const Track* b) { return a->last_access_ms > b->last_access_ms; });
        return rank < n ? order[rank] : nullptr;
    }
    static bool contains(const Plan& plan, std::uint64_t object, std::uint32_t chunk) noexcept {
        for (std::size_t i = 0; i < plan.count; ++i)
            if (plan.entries[i].object == object && plan.entries[i].chunk == chunk) return true;
        return false;
    }
};

// Read advice for one file range. Darwin: F_RDADVISE schedules an
// asynchronous read of the range into the unified buffer cache; Linux:
// posix_fadvise(WILLNEED). Returns 0 or the errno. Advice only: it neither
// blocks nor guarantees residency, so the worker still reads with pread()
// and validates. Never call on a frame thread.
inline int advise_read(int fd, std::uint64_t offset, std::uint64_t length) noexcept {
    if (fd < 0 || !length || offset > static_cast<std::uint64_t>(INT64_MAX) ||
        length > static_cast<std::uint64_t>(INT32_MAX)) return EINVAL;
#if defined(__APPLE__)
    struct radvisory advice{};
    advice.ra_offset = static_cast<off_t>(offset);
    advice.ra_count = static_cast<int>(length);
    return ::fcntl(fd, F_RDADVISE, &advice) < 0 ? errno : 0;
#else
    return ::posix_fadvise(fd, static_cast<off_t>(offset), static_cast<off_t>(length), POSIX_FADV_WILLNEED);
#endif
}
// Automatic read-ahead of the descriptor. Darwin F_RDAHEAD; Linux sequential
// versus normal advice. Sequential restores of a run benefit; random
// demand reads of a cold file do not, so the worker toggles it per plan.
inline int set_readahead(int fd, bool enabled) noexcept {
    if (fd < 0) return EINVAL;
#if defined(__APPLE__)
    return ::fcntl(fd, F_RDAHEAD, enabled ? 1 : 0) < 0 ? errno : 0;
#else
    return ::posix_fadvise(fd, 0, 0, enabled ? POSIX_FADV_SEQUENTIAL : POSIX_FADV_NORMAL);
#endif
}
// Pre-fault a mapped window on the worker: one volatile read per page so
// the consumer's later reads never take a disk fault on its own thread.
// Returns the number of pages touched. The window must be a readable mapping
// owned by the caller for the whole call.
inline std::size_t prefault(const void* window, std::size_t bytes, std::size_t page_bytes) noexcept {
    if (!window || !bytes || !page_bytes) return 0;
    const auto* base = static_cast<const volatile unsigned char*>(window);
    std::size_t pages = 0;
    for (std::size_t offset = 0; offset < bytes; offset += page_bytes, ++pages) (void)base[offset];
    return pages;
}
} // namespace neostation::prefetch
