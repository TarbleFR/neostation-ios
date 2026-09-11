bool prepare_arena(bool expanded) noexcept
{
	std::lock_guard lock(g_arena_mutex);
	if (g_arena.prepared)
	{
		if (g_arena.expanded != expanded)
		{
			set_error("JIT arena capacity policy changed after preparation; relaunch is required");
			return false;
		}
		return true;
	}

	const arena_backend backend = current_backend();
	if (backend == arena_backend::legacy_debugger && !legacy_debugger_is_ready())
	{
		return false;
	}
	if (!write_protect_function())
	{
		set_error("pthread_jit_write_protect_np is unavailable in this iOS runtime");
		return false;
	}

	const usz capacity = choose_arena_capacity(physical_memory_size(), expanded);
	if (!capacity || capacity > std::numeric_limits<usz>::max() / 2)
	{
		set_error("Invalid JIT arena capacity");
		return false;
	}

	// NEOSTATION_DYNAMIC_JIT_V1: one OS-selected mapping, no RX/RW remap.
	// MAP_FIXED is incompatible with MAP_JIT. All relocation addresses and
	// generated function pointers refer to exactly the bytes LLVM/ASM writes.
	auto* const code = static_cast<u8*>(::mmap(nullptr, capacity,
		PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT,
		jit_vm_tag, 0));
	if (code == MAP_FAILED)
	{
		set_error("Unable to allocate dynamic MAP_JIT code: " + std::string{std::strerror(errno)});
		return false;
	}

	// Mutable data must remain ordinary RW memory while this thread executes
	// JIT code. Use an address hint, never overwrite an existing host mapping.
	const uptr code_address = reinterpret_cast<uptr>(code);
	auto* const data = static_cast<u8*>(::mmap(reinterpret_cast<void*>(code_address + capacity),
		capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, jit_vm_tag, 0));
	if (data == MAP_FAILED)
	{
		const std::string detail = std::strerror(errno);
		::munmap(code, capacity);
		set_error("Unable to allocate dynamic JIT data: " + detail);
		return false;
	}
	// ARM64's small code model uses signed page-relative relocations. The OS
	// can ignore the hint; reject an out-of-range result before LLVM uses it.
	const uptr data_address = reinterpret_cast<uptr>(data);
	const uptr distance = code_address > data_address
		? code_address - data_address : data_address - code_address;
	if (distance >= 0x100000000ull - capacity)
	{
		::munmap(data, capacity);
		::munmap(code, capacity);
		set_error("Dynamic JIT code/data exceed the ARM64 relocation range");
		return false;
	}

	// Complete Universal preparation for the actual mapping before detach.
	// The debugger must never select a different executable address.
	u32 preparation_chunks = 0;
	if (backend == arena_backend::universal_mirrored)
	{
		if (protocol_call(command_prepare_region, code, capacity) != code_address)
		{
			::munmap(data, capacity);
			::munmap(code, capacity);
			set_error("Universal JIT did not prepare the dynamic code mapping");
			return false;
		}
		preparation_chunks = 1;
	}

	g_arena.code_allocator.reset(capacity);
	g_arena.data_allocator.reset(capacity);
	g_arena.code = code;
	g_arena.data = data;
	g_arena.capacity = capacity;
	g_arena.preparation_chunks = preparation_chunks;
	g_arena.backend = backend;
	g_arena.expanded = expanded;
	g_arena.prepared = true;
	return true;
}
