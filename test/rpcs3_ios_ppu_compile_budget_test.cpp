#include "rpcs3/ios/IOSMemoryPressurePolicy.h"

#include <cassert>
#include <cstdint>
#include <limits>

int main()
{
	using rpcs3::ios::get_ppu_module_file_budget;
	using rpcs3::ios::get_process_memory_pressure;
	using rpcs3::ios::is_god_of_war_iii_title;
	using rpcs3::ios::process_memory_pressure;
	constexpr std::uint64_t gib = std::uint64_t{1} << 30;
	constexpr std::uint64_t mib = std::uint64_t{1} << 20;
	constexpr std::uint64_t physical = 8 * gib;
	constexpr auto expected_two_gib = (2 * gib / 4 * 3 + 1999) / 2000;

	static_assert(get_ppu_module_file_budget(physical, 2 * gib) == expected_two_gib);
	static_assert(get_ppu_module_file_budget(physical, 0) == 65'536);
	static_assert(get_ppu_module_file_budget(physical, physical * 2) ==
		get_ppu_module_file_budget(physical, physical));
	static_assert(get_ppu_module_file_budget(std::numeric_limits<std::uint64_t>::max(),
		std::numeric_limits<std::uint64_t>::max()) == std::numeric_limits<std::uint32_t>::max());
	static_assert(is_god_of_war_iii_title("BCES00510"));
	static_assert(!is_god_of_war_iii_title("OTHER0001"));
	static_assert(get_process_memory_pressure(2 * gib) == process_memory_pressure::low);
	static_assert(get_process_memory_pressure(2 * gib, process_memory_pressure::low, true) ==
		process_memory_pressure::moderate);
	static_assert(get_process_memory_pressure(2700 * mib, process_memory_pressure::moderate, true) ==
		process_memory_pressure::moderate);
	static_assert(get_process_memory_pressure(2900 * mib, process_memory_pressure::moderate, true) ==
		process_memory_pressure::low);
	static_assert(get_process_memory_pressure(gib, process_memory_pressure::low, true) ==
		process_memory_pressure::severe);

	// More iOS headroom allows more in-flight module bytes; a critical low
	// allowance still admits one oversized module through the queue's floor.
	assert(get_ppu_module_file_budget(physical, gib / 2) == 201'327);
	assert(get_ppu_module_file_budget(physical, gib) < get_ppu_module_file_budget(physical, 2 * gib));
}
