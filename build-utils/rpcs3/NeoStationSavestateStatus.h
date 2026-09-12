// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstdint>
#include <mutex>
#include <string>
#include <utility>

namespace neostation::savestate
{
enum class phase : std::uint32_t
{
    idle = 0, preparing = 1, writing = 2, restarting = 3,
    succeeded = 4, failed = 5,
};

struct snapshot
{
    phase state;
    bool active;
    bool committed;
    std::string message;
};

class operation
{
    mutable std::mutex mutex;
    snapshot value{phase::idle, false, false, {}};
public:
    bool begin()
    {
        std::lock_guard lock(mutex);
        if (value.active) return false;
        value = {phase::preparing, true, false, {}};
        return true;
    }
    snapshot read() const
    {
        std::lock_guard lock(mutex);
        return value;
    }
    void advance(phase state)
    {
        std::lock_guard lock(mutex);
        if (value.active) value.state = state;
    }
    void error(std::string message)
    {
        std::lock_guard lock(mutex);
        if (value.active) value.message = std::move(message);
    }
    void record_write(bool committed)
    {
        std::lock_guard lock(mutex);
        if (!value.active) return;
        value.committed = committed;
        if (!committed && value.message.empty())
            value.message = "RPCS3 could not finish writing the savestate. The previous savestates were not replaced.";
    }
    void finish(bool success, std::string fallback = {})
    {
        std::lock_guard lock(mutex);
        if (!value.active) return;
        value.state = success ? phase::succeeded : phase::failed;
        value.active = false;
        if (!success && value.message.empty()) value.message = std::move(fallback);
    }
};

inline operation current;
}
