#include "rpcs3/Emu/Cell/SPUWarmupPolicy.h"
#include <array>
#include <cassert>
#include <iostream>
#include <future>
#include <stdexcept>
#include <thread>
#include <vector>

using u8 = std::uint8_t;
using u32 = std::uint32_t;
using usz = std::size_t;
using spu_function_t = void(*)();
static void compiled_function() {}
struct atomic_wait_timeout { std::uint64_t value; };

template <typename T> struct fixture_atomic
{
	T value{};
	int* waits{};
	operator T() const { return value; }
	T load() const { return value; }
	fixture_atomic& operator=(T next) { value = next; return *this; }
	T compare_and_swap(T expected, T desired)
	{
		T before = value;
		if (value == expected) value = desired;
		return before;
	}
	void wait(T, atomic_wait_timeout) { ++*waits; assert(false && "ready/failed blocks must never wait"); }
};
struct spu_program
{
	static inline bool fail_copy = false;
	u32 entry_point;
	std::vector<u32> data;
	spu_program(u32 entry, std::vector<u32> words) : entry_point(entry), data(std::move(words)) {}
	spu_program(const spu_program& other) : entry_point(other.entry_point)
	{
		if (fail_copy) throw std::bad_alloc{};
		data = other.data;
	}
	spu_program(spu_program&&) = default;
};
struct fixture_item
{
	spu_program data;
	fixture_atomic<spu_function_t> compiled;
	fixture_atomic<u32> llvm_compile_state;
	fixture_atomic<u8> warmed;
	fixture_atomic<u8> cached;
};
struct fixture_runtime
{
	fixture_item* item;
	bool published = false;
	fixture_item* add_empty(spu_program&&) { published = true; return item; }
};
namespace rpcs3::ios
{
static unsigned reuse_count;
void record_spu_warm_reuse() noexcept { ++reuse_count; }
}
struct fixture_compiler
{
	fixture_runtime* m_spurt;
	unsigned heavy_compiles = 0;
	spu_function_t compile(spu_program&& _func)
	{
#include "SPUCompileClaim.inc"
		assert(func_size == 1);
		++heavy_compiles;
		add_loc->compiled.value = compiled_function;
		add_loc->llvm_compile_state.value = 2;
		return compiled_function;
	}
};

using spu_recompiler_base = fixture_compiler;
struct spu_llvm_compile_context {};
struct spu_llvm_compile_scope { spu_llvm_compile_scope(spu_llvm_compile_context&, bool) {} };
#include "SPURetryFirstAttempt.inc"

int main()
{
	using namespace rpcs3::spu;
	// Cache presence must not discard known new modules for the targeted title.
	assert(precompile_discovered(true, true, true, false));
	assert(precompile_discovered(true, true, false, true));
	assert(!precompile_discovered(true, true, false, false));
	assert(!precompile_discovered(false, true, false, true));
	assert(!precompile_discovered(true, false, true, true));
	assert(warmup_worker_count(12, 0, true) == 2);
	assert(warmup_worker_count(12, 1, true) == 1);
	assert(warmup_worker_count(1, 12, true) == 1);
	assert(warmup_worker_count(0, 12, true) == 0);
	assert(warmup_worker_count(12, 0, false) == 12);
	assert(!loading_warmup);
	{
		warmup_scope scope;
		assert(loading_warmup);
		{ warmup_scope nested; assert(loading_warmup); }
		assert(loading_warmup);
	}
	assert(!loading_warmup);
	std::array<u32, 8> ls{1,2,3,4,5,6,7,8};
	clear_warmup_local_store(std::span{ls.data() + 3, 1u});
	assert(ls[3] == 0 && ls[2] == 3 && ls[4] == 5);
	clear_warmup_local_store(std::span{ls.data() + 5, 3u});
	assert(ls[4] == 5 && ls[5] == 0 && ls[6] == 0 && ls[7] == 0);
	compile_counters counters;
	counters.record(5, true);
	counters.record(19, false);
	auto first = counters.take();
	assert(first.count == 2 && first.failures == 1 && first.ticks == 24 && first.maximum_ticks == 19);
	assert(counters.take().count == 0);
	// Telemetry may be recorded by the existing bounded pool concurrently.
	std::array<std::thread, 2> writers;
	for (auto& writer : writers) writer = std::thread([&] { for (int i=0;i<1000;++i) counters.record(i, true); });
	for (auto& writer : writers) writer.join();
	auto concurrent = counters.take();
	assert(concurrent.count == 2000 && concurrent.ticks == 999000 && concurrent.maximum_ticks == 999);

	// Failure/cancellation before phase arrival must not strand another worker.
	for (const bool failed : {false, true})
	{
		std::barrier barrier{2};
		auto first_worker = std::async(std::launch::async, [&]
		{
			try
			{
				warmup_barrier_guard guard{barrier};
				if (failed) throw std::runtime_error("compiler initialization failed");
				guard.wait();
			}
			catch (const std::runtime_error&) {}
		});
		auto second_worker = std::async(std::launch::async, [&]
		{
			warmup_barrier_guard guard{barrier};
			guard.wait();
		});
		assert(first_worker.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
		assert(second_worker.wait_for(std::chrono::seconds(2)) == std::future_status::ready);
		first_worker.get();
		second_worker.get();
	}

	int waits = 0;
	fixture_item item{{0x100, {42}}, {compiled_function, &waits}, {2, &waits}, {1, &waits}, {0, &waits}};
	fixture_runtime runtime{&item};
	fixture_compiler compiler{&runtime};
	assert(compiler.compile({0x100, {42}}) == compiled_function);
	assert(compiler.compile({0x200, {42}}) == compiled_function);
	assert(compiler.heavy_compiles == 0 && waits == 0 && rpcs3::ios::reuse_count == 2);
	{
		warmup_scope scope;
		assert(compiler.compile({0x100, {42}}) == compiled_function);
		assert(rpcs3::ios::reuse_count == 2);
	}
	item.compiled.value = nullptr;
	item.llvm_compile_state.value = 3;
	assert(compiler.compile({0x100, {42}}) == nullptr);
	assert(compiler.compile({0x200, {42}}) == nullptr);
	assert(compiler.heavy_compiles == 0 && waits == 0);
	// A new session/item must compile once; a second call reuses that item.
	item.warmed.value = 0;
	item.llvm_compile_state.value = 0;
	assert(compiler.compile({0x100, {42}}) == compiled_function);
	assert(compiler.compile({0x100, {42}}) == compiled_function);
	assert(compiler.heavy_compiles == 1 && waits == 0);
	// Execute the production ARM64 retry wrapper's potentially throwing copy.
	// It must fail before any runtime insertion, and unwind metadata TLS state.
	fixture_item fresh{{0x100, {42}}, {nullptr, &waits}, {0, &waits}, {0, &waits}, {0, &waits}};
	fixture_runtime fresh_runtime{&fresh};
	auto retry_compiler = std::make_unique<spu_recompiler_base>(fixture_compiler{&fresh_runtime});
	const spu_program known{0x100, {42}};
	spu_program::fail_copy = true;
	try
	{
		metadata_replay_scope scope;
		static_cast<void>(compile_spu_llvm_with_retry(retry_compiler, known));
		assert(false && "copy must fail before runtime publication");
	}
	catch (const std::bad_alloc&) {}
	spu_program::fail_copy = false;
	assert(!fresh_runtime.published && !replaying_metadata);
	assert(fresh.llvm_compile_state.value == 0 && !fresh.compiled.value);
	{
		metadata_replay_scope scope;
		assert(compile_spu_llvm_with_retry(retry_compiler, known) == compiled_function);
	}
	assert(fresh_runtime.published && fresh.cached.value == 1 && !replaying_metadata);
	assert(retry_compiler->compile({0x200, {42}}) == compiled_function);
	assert(retry_compiler->heavy_compiles == 1 && waits == 0);
	std::cout << "SPU warmup behavior: PASS\n";
}
