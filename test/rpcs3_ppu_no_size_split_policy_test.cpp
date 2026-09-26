#include "rpcs3/Emu/Cell/PPUNoSizeSplitPolicy.h"

#include <cassert>
#include <cstdint>

int main()
{
	using ppu_analysis::split_unbounded_blocks;
	constexpr std::uint64_t limit = ppu_analysis::max_unbounded_split_instructions;

	// Keep the original small-module behavior and the existing fallback path.
	static_assert(split_unbounded_blocks(false, 0));
	static_assert(split_unbounded_blocks(false, limit * 4));
	static_assert(!split_unbounded_blocks(true, 0));
	static_assert(!split_unbounded_blocks(true, limit * 4));

	// The first instruction beyond the bound must avoid per-instruction JIT
	// functions, even when the module has more than 4 GiB of total code bytes.
	static_assert(!split_unbounded_blocks(false, (limit + 1) * 4));
	static_assert(!split_unbounded_blocks(false, (std::uint64_t{1} << 32) + 4));

	assert(split_unbounded_blocks(false, 64));
	assert(!split_unbounded_blocks(false, (limit + 1) * 4));
}
