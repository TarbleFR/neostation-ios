// Imported from XITRIX/rpcs3 ios-port, GPL-2.0; upstream v0.10.1 regression fixture.
#include <array>
#include <cstdint>
#include <iostream>
#include <set>
#include <stdexcept>

using u32 = std::uint32_t;
static unsigned checks = 0;
static void require(bool value, const char* message)
{
	++checks;
	if (!value) throw std::runtime_error(message);
}

// Distinct types exercise both instantiations of the production generic lambda.
template <bool Vertex>
struct Texture
{
	bool active = false;
	u32 address = 0x02bd9000;
	u32 domain = 1;
	bool enabled() const { return active; }
	u32 offset() const { return address; }
	u32 location() const { return domain; }
};

namespace rsx
{
	struct Registers
	{
		std::array<Texture<false>, 16> fragment_textures;
		std::array<Texture<true>, 4> vertex_textures;
	} method_registers;
	static unsigned lookups = 0;
	static bool main_mapped = false;
	struct Unmapped : std::runtime_error
	{
		Unmapped() : std::runtime_error("RSXIO memory not mapped!") {}
	};
	u32 get_address(u32 offset, u32 location)
	{
		++lookups;
		if (location == 0) return 0xc0000000u + offset;
		if (location == 1 && main_mapped && (offset >> 20) == 0x2b) return 0x40000000u + offset;
		throw Unmapped();
	}
}

static std::set<u32> scan()
{
	// Includes both array calls as well as the loop, directly from production.
#include "VKMemoryPressureScan.inc"
	return exclusion_list;
}

int main()
{
	// GT6's disabled fragment slot 4 retains 0x2bd9000 after unmapping IO
	// 0x2b00000..0x2bfffff. All disabled slots must be safe even with stale data.
	require(scan().empty(), "disabled stale textures must not prevent cache eviction");
	require(rsx::lookups == 0, "disabled textures must not resolve addresses");

	// Exhaust every enable mask for each texture stage. Active textures remain
	// protected; disabled stale main-memory addresses must never be looked up.
	auto masks = [](auto& textures)
	{
		for (u32 mask = 0; mask < (1u << textures.size()); ++mask)
		{
			std::set<u32> expected;
			for (u32 i = 0; i < textures.size(); ++i)
			{
				textures[i] = {};
				if (mask & (1u << i))
				{
					textures[i].active = true;
					textures[i].domain = 0;
					textures[i].address = i * 0x1000;
					expected.insert(0xc0000000u + i * 0x1000);
				}
			}
			rsx::lookups = 0;
			require(scan() == expected, "active eviction exclusions changed");
			require(rsx::lookups == expected.size(), "disabled slot was translated");
		}
		textures = {};
	};
	masks(rsx::method_registers.fragment_textures);
	masks(rsx::method_registers.vertex_textures);

	// Local offset zero is valid. Duplicate aliases in both stages remain
	// protected once, while their enabled mappings are all validated.
	rsx::method_registers.fragment_textures[0] = {true, 0, 0};
	rsx::method_registers.fragment_textures[1] = {true, 0x02bd9000, 1};
	rsx::method_registers.vertex_textures[3] = {true, 0x02bd9000, 1};
	rsx::main_mapped = true;
	rsx::lookups = 0;
	require(scan() == std::set<u32>({0xc0000000, 0x42bd9000}), "mixed-stage aliases lost protection");
	require(rsx::lookups == 3, "enabled aliases were not validated");

	// A disabled mapping can be unmapped safely; genuinely enabled invalid
	// mappings must still fail rather than silently evicting active resources.
	rsx::method_registers.fragment_textures[1].active = false;
	rsx::method_registers.vertex_textures[3].active = false;
	rsx::main_mapped = false;
	require(scan() == std::set<u32>{0xc0000000}, "disabled unmapped alias retained");
	auto rejects_unmapped = [](auto& texture)
	{
		texture.active = true;
		bool rejected = false;
		try { (void)scan(); }
		catch (const rsx::Unmapped&) { rejected = true; }
		require(rejected, "enabled unmapped texture error was suppressed");
		texture.active = false;
	};
	rejects_unmapped(rsx::method_registers.fragment_textures[1]);
	rejects_unmapped(rsx::method_registers.vertex_textures[3]);
	std::cout << "Vulkan memory-pressure exclusion scan: " << checks << " checks passed\n";
}
