#include "rpcs3/ios/IOSMemoryPressurePolicy.h"

#include <cassert>
#include <cstdint>
#include <limits>

int main()
{
	using rpcs3::ios::get_ppu_module_file_budget;
	constexpr std::uint64_t gib = std::uint64_t{1} << 30;
	constexpr std::uint64_t physical = 8 * gib;
	constexpr auto expected_two_gib = (2 * gib / 4 * 3 + 1999) / 2000;

	static_assert(get_ppu_module_file_budget(physical, 2 * gib) == expected_two_gib);
	static_assert(get_ppu_module_file_budget(physical, 0) == 65'536);
	static_assert(get_ppu_module_file_budget(physical, physical * 2) ==
		get_ppu_module_file_budget(physical, physical));
	static_assert(get_ppu_module_file_budget(std::numeric_limits<std::uint64_t>::max(),
		std::numeric_limits<std::uint64_t>::max()) == std::numeric_limits<std::uint32_t>::max());

	// More iOS headroom allows more in-flight module bytes; a critical low
	// allowance still admits one oversized module through the queue's floor.
	assert(get_ppu_module_file_budget(physical, gib / 2) == 201'327);
	assert(get_ppu_module_file_budget(physical, gib) < get_ppu_module_file_budget(physical, 2 * gib));
}
