// Imported from XITRIX/rpcs3 ios-port, GPL-2.0; upstream v0.10.1 regression fixture.
#include "stdafx.h"
#include "Emu/Cell/SPURecompiler.h"
#include "Emu/Cell/SPUDisAsm.h"
#include "Emu/system_config_types.h"
#include "Crypto/sha1.h"
#include "util/asm.hpp"
#include "Emu/Cell/Modules/cellSync.h"
#include <iostream>
#include <fstream>
#include <set>
#include <unordered_set>
const extern spu_decoder<spu_itype> g_spu_itype{};
const extern spu_decoder<spu_iname> g_spu_iname{};
const extern spu_decoder<spu_iflag> g_spu_iflag{};
constexpr u32 s_reg_max = spu_recompiler_base::s_reg_max;
struct
{
	struct
	{
		spu_block_size_type spu_block_size = spu_block_size_type::safe;
		bool spu_debug = false;
		bool spu_accurate_reservations = true;
	} core;
} fixture_cfg;
struct fixture_types
{
	template <class T>
	T& get()
	{
		static T obj;
		return obj;
	}
} fixture_types_instance;
constexpr auto fixture_fxo = &fixture_types_instance;
struct sink
{
	bool enabled = false;
	template <class... T>
	void operator()(T&&...) const
	{
	}
	constexpr explicit operator bool() const
	{
		return enabled;
	}
	const sink& operator()() const
	{
		return *this;
	}
};
const struct
{
	sink notice, warning, error, success, trace, always, fatal, todo;
} fixture_log;
#define g_cfg fixture_cfg
#define g_fxo fixture_fxo
#define spu_log fixture_log
#include "SPUMailboxTestSupport.inc"
#include "SPUMailboxBranchTargets.inc"
#include "SPUMailboxAnalyzer.inc"
spu_recompiler_base::spu_recompiler_base() {}
spu_recompiler_base::~spu_recompiler_base() {}
void spu_recompiler_base::dump(const spu_program&, std::string&, u32, u32) {}
struct analyzer : spu_recompiler_base
{
	using spu_recompiler_base::inst_attr;
	using spu_recompiler_base::m_inst_attrs;
	using spu_recompiler_base::m_patterns;
	using spu_recompiler_base::m_targets;
	using spu_recompiler_base::m_bbs;
	using spu_recompiler_base::m_block_info;
	void init() override {}
	spu_function_t compile(spu_program&&) override
	{
		return nullptr;
	}
};


// The LLVM and ASMJIT fall-through guards are extracted from production sources.
#include "SPUBranchGuards.inc"
static unsigned cases = 0;
static void check(const std::vector<u32>& code, u32 base, u32 branch_offset, bool fallthrough)
{
	auto a = std::make_unique<analyzer>();
	std::vector<be_t<u32>> ls(65536);
	for (usz i = 0; i < code.size(); ++i) ls[base / 4 + i] = code[i];
	const auto program = a->analyse(ls.data(), base);
	const u32 pc = base + branch_offset;
	const auto op = spu_opcode_t{code[branch_offset / 4]};
	ensure(llvm_fallthrough(a->m_targets, pc, op) == fallthrough);
	ensure(asmjit_fallthrough(a->m_targets, pc, op) == fallthrough);
	if (fallthrough)
	{
		// A recorded target must survive analyzer pruning as a real block.
		ensure(a->m_targets.at(pc) == std::vector<u32>{pc + 4});
		ensure(a->m_block_info[(pc + 4) / 4]);
		ensure(a->m_bbs.count(pc + 4));
		ensure(program.lower_bound + program.data.size() * 4 > pc + 4);
	}
	for (usz i = 0; i < program.data.size(); ++i)
		if (program.data[i]) ensure(program.data[i] == std::bit_cast<u32>(ls[program.lower_bound / 4 + i]));
	++cases;
}
static void check_loop(u32 base)
{
	// Two predecessors feed the loop header. BID must split its block so the
	// backedge comes from the continuation, never from a block that exits at BID.
	const std::vector<u32> code = {
		0x20000107, // BRZ r7,base+8
		0x35000000, // BI lr
		0x01a006b1, // RDCH r49,SPU_RdMachStat
		0x33000082, // BRSL r2,next
		0x1c020102, // AI r2,r2,8
		0x35080100, // BID r2
		0x1c004183, // AI r3,r3,1
		0x237ffda8, // BRHNZ r40,base+8
		0x35000000, // BI lr
	};
	std::vector<be_t<u32>> ls(65536);
	for (usz i = 0; i < code.size(); ++i) ls[base / 4 + i] = code[i];
	auto a = std::make_unique<analyzer>();
	const auto program = a->analyse(ls.data(), base);
	ensure(program.data.size() == code.size());
	ensure(llvm_fallthrough(a->m_targets, base + 20, spu_opcode_t{code[5]}));
	ensure(asmjit_fallthrough(a->m_targets, base + 20, spu_opcode_t{code[5]}));
	ensure(a->m_bbs.at(base + 8).targets == std::vector<u32>{base + 24});
	ensure(a->m_bbs.at(base + 24).targets == std::vector<u32>({base + 8, base + 32}));
	const auto& preds = a->m_bbs.at(base + 8).preds;
	ensure(std::set<u32>(preds.begin(), preds.end()) == std::set<u32>({base, base + 24}));
	++cases;
}

int main(int argc, char** argv)
{
	if (argc >= 2)
	{
		// Optional full 256 KiB local-store reconstruction from a user log.
		const bool dark_souls = argc == 3 && std::string_view(argv[2]) == "dark-souls2";
		const u32 entry = dark_souls ? 0x5650 : 0xbf18;
		const u32 size = dark_souls ? 212 : 171;
		const u32 bid = dark_souls ? 0x5914 : 0xc17c;
		const u32 old_pred = dark_souls ? 0x5904 : 0xc16c;
		const u32 merge = dark_souls ? 0x57c0 : 0xc050;
		const u32 exit = dark_souls ? 0x5994 : 0xc1b8;
		g_cfg.core.spu_block_size = spu_block_size_type::mega;
		std::ifstream file(argv[1], std::ios::binary);
		std::vector<be_t<u32>> ls(65536);
		file.read(reinterpret_cast<char*>(ls.data()), ls.size() * sizeof(ls[0]));
		ensure(file.gcount() == SPU_LS_SIZE);
		auto a = std::make_unique<analyzer>();
		const auto program = a->analyse(ls.data(), entry);
		ensure(program.entry_point == entry && program.data.size() == size);
		ensure(llvm_fallthrough(a->m_targets, bid, spu_opcode_t{ls[bid / 4]}));
		ensure(asmjit_fallthrough(a->m_targets, bid, spu_opcode_t{ls[bid / 4]}));
		// The DMA and following conditional branch must remain reachable.
		ensure(a->m_bbs.at(old_pred).targets == std::vector<u32>{bid + 4});
		ensure(a->m_bbs.at(bid + 4).targets == std::vector<u32>({merge, exit}));
		const auto& preds = a->m_bbs.at(merge).preds;
		ensure(std::find(preds.begin(), preds.end(), bid + 4) != preds.end());
		ensure(std::find(preds.begin(), preds.end(), old_pred) == preds.end());
		std::cout << "Reported SPU block at 0x" << std::hex << entry << std::dec
		          << ": " << size << " instructions; BID continuation and merge predecessors passed\n";
		++cases;
	}
	for (auto mode : {spu_block_size_type::safe, spu_block_size_type::mega, spu_block_size_type::giga})
	{
		g_cfg.core.spu_block_size = mode;
		for (u32 base : {0x100u, 0xc16cu, 0x3ffc0u})
		{
			check_loop(base);
			// BRSL r2,next; AI r2,r2,8; BID r2; AI r3,r3,1; BI lr.
			// The continuation has a visible register write, not just NOPs.
			check({0x33000082,0x1c020102,0x35080100,0x1c004183,0x35000000}, base, 8, true);
			// Same idiom preceded by RdMachStat, as in the reported demo.
			check({0x01a0069d,0x33000082,0x1c020102,0x35080100,0x1c004183,0x35000000}, base, 12, true);
			// Enabling interrupts must retain the interrupt-delivery branch.
			check({0x33000082,0x1c020102,0x35040100,0x1c004183,0x35000000}, base, 8, false);
			// Unknown targets and non-fallthrough BID must still dispatch.
			check({0x35080100,0x1c004183,0x35000000}, base, 0, false);
			check({0x33000082,0x1c030102,0x35080100,0x1c004183,0x35000000}, base, 8, false);
		}
	}
	std::cout << "SPU branch analyzer/backend agreement: " << cases << " cases passed\n";
}
