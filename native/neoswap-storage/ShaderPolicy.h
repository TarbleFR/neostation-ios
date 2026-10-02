// SPDX-License-Identifier: MIT
#pragma once
#include <string_view>
namespace neostation::storage {
inline bool shader_storage_title(std::string_view title) noexcept {
    return title=="BCES00510" || title=="BCES00799" || title=="BCUS98111" ||
        title=="BCJS37001" || title=="BCAS25003" || title=="BCKS15003";
}
} // namespace neostation::storage
