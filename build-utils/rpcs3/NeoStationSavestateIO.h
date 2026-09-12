// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once

#include <cstddef>
#include <utility>
#include <zstd.h>

namespace neostation::savestate
{
// Same lossless ZSTD format as existing savestates. Trade some disk space for
// shorter capture pauses and less compression work on mobile CPUs.
inline constexpr int compression_level = 3;

struct decoder_context
{
    ZSTD_DCtx* m_zd = nullptr;
    decoder_context() = default;
    decoder_context(const decoder_context&) = delete;
    decoder_context& operator=(const decoder_context&) = delete;
    ~decoder_context() { reset(); }
    void reset() noexcept
    {
        // ZSTD_freeDCtx returns zero on success; it is not a Boolean predicate.
        static_cast<void>(ZSTD_freeDCtx(std::exchange(m_zd, nullptr)));
    }
};

template <typename Write>
bool write_complete(Write&& write, const void* data, std::size_t size)
{
    const auto* bytes = static_cast<const unsigned char*>(data);
    while (size)
    {
        const auto written = write(bytes, size);
        if (!written || written > size) return false;
        bytes += written;
        size -= written;
    }
    return true;
}
}
