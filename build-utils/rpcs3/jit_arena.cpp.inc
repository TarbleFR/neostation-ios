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

	const usz capacity = choose_arena_capacity(physical_memory_size(), expanded);
	if (!capacity || capacity > std::numeric_limits<usz>::max() / 2)
	{
		set_error("Invalid JIT arena capacity");
		return false;
	}

	// NEOSTATION_DYNAMIC_JIT_V4
	//
	// Keep code and mutable JIT data in one contiguous reservation. RPCS3's
	// ARM64 small code model relies on this relationship and the kernel is free
	// to ignore an ordinary mmap address hint. The previous V3 experiment let
	// debugserver choose the executable address first and then merely hinted the
	// data mapping beside it; that made the layout unnecessarily fragile.
	//
	// Universal JIT still prepares the *actual* RX code pages through StikJIT.
	// The companion Build 240 StikJIT patch sends full-width page addresses and
	// rejects debugger refusal replies, so command-1 success now means the pages
	// at this exact address were really accepted instead of a truncated alias.
	const usz total_size = capacity * 2;
	auto* const layout = static_cast<u8*>(::mmap(
		nullptr,
		total_size,
		PROT_NONE,
		MAP_PRIVATE | MAP_ANON,
		-1,
		0));
	if (layout == MAP_FAILED)
	{
		set_error("Unable to reserve the contiguous JIT code/data layout: " + std::string{std::strerror(errno)});
		return false;
	}

	const int initial_code_protection = backend == arena_backend::universal_mirrored
		? PROT_READ | PROT_EXEC
		: PROT_READ | PROT_WRITE;
	void* const code_mapping = ::mmap(
		layout,
		capacity,
		initial_code_protection,
		MAP_FIXED | MAP_PRIVATE | MAP_ANON,
		-1,
		0);
	if (code_mapping != layout)
	{
		const std::string detail = std::strerror(errno);
		::munmap(layout, total_size);
		set_error("Unable to map the contiguous JIT code arena: " + detail);
		return false;
	}

	void* const data_mapping = ::mmap(
		layout + capacity,
		capacity,
		PROT_READ | PROT_WRITE,
		MAP_FIXED | MAP_PRIVATE | MAP_ANON,
		-1,
		0);
	if (data_mapping != layout + capacity)
	{
		const std::string detail = std::strerror(errno);
		::munmap(layout, total_size);
		set_error("Unable to map the contiguous JIT data arena: " + detail);
		return false;
	}

	u32 preparation_chunks = 0;
	if (backend == arena_backend::universal_mirrored)
	{
		// Keep requests bounded exactly like the pinned iOS Core. A failed page
		// batch must be visible as a failed command instead of being hidden by the
		// debugger script; the patched StikJIT side enforces that contract.
		preparation_chunks = arena_prepare_chunk_count(capacity);
		for (u32 chunk_index = 0; chunk_index < preparation_chunks; ++chunk_index)
		{
			const usz offset = static_cast<usz>(chunk_index) * arena_prepare_chunk_size;
			const usz chunk_length = arena_prepare_chunk_length(capacity, chunk_index);
			u8* const chunk = layout + offset;
			if (!chunk_length ||
				protocol_call(command_prepare_region, chunk, chunk_length) != reinterpret_cast<uptr>(chunk))
			{
				::munmap(layout, total_size);
				set_error("Universal JIT rejected arena chunk " + std::to_string(chunk_index + 1) +
					" of " + std::to_string(preparation_chunks) +
					"; inspect the StikJIT page-response diagnostic");
				return false;
			}
		}
	}

	// The executable address never changes. LLVM and ASMJIT write through a
	// shared RW alias of those exact pages, then flush the RX view before use.
	vm_address_t writable_address = 0;
	vm_prot_t current_protection = VM_PROT_NONE;
	vm_prot_t maximum_protection = VM_PROT_NONE;
	const kern_return_t remap_result = ::vm_remap(
		mach_task_self(),
		&writable_address,
		static_cast<vm_size_t>(capacity),
		0,
		VM_FLAGS_ANYWHERE,
		mach_task_self(),
		static_cast<vm_address_t>(reinterpret_cast<uptr>(layout)),
		false,
		&current_protection,
		&maximum_protection,
		VM_INHERIT_SHARE);
	if (remap_result != KERN_SUCCESS)
	{
		::munmap(layout, total_size);
		set_error("Unable to create the JIT writable alias");
		return false;
	}

	if (::vm_protect(
			mach_task_self(),
			writable_address,
			static_cast<vm_size_t>(capacity),
			false,
			VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS)
	{
		::vm_deallocate(mach_task_self(), writable_address, static_cast<vm_size_t>(capacity));
		::munmap(layout, total_size);
		set_error("Unable to protect the JIT writable alias");
		return false;
	}

	if (backend == arena_backend::legacy_debugger &&
		::mprotect(layout, capacity, PROT_READ | PROT_EXEC) != 0)
	{
		const std::string detail = std::strerror(errno);
		::vm_deallocate(mach_task_self(), writable_address, static_cast<vm_size_t>(capacity));
		::munmap(layout, total_size);
		set_error("Unable to transition the legacy JIT arena to executable: " + detail);
		return false;
	}

	auto* const writable_code = reinterpret_cast<u8*>(writable_address);

	// Prove that the final write and execute views are the same VM object before
	// any generated function pointer can escape. This catches a detached/COW
	// remap independently of the debugger's page-preparation acknowledgement.
	for (const usz offset : {usz{0}, capacity / 2, capacity - page_size()})
	{
		auto* const writer = reinterpret_cast<volatile u64*>(writable_code + offset);
		auto* const reader = reinterpret_cast<volatile const u64*>(layout + offset);
		const u64 saved = *writer;
		bool coherent = true;
		for (const u64 pattern : {u64{0x13579bdf2468ace0}, u64{0xfedcba9876543210}})
		{
			*writer = pattern;
			::sys_dcache_flush(const_cast<u64*>(writer), sizeof(u64));
			::sys_icache_invalidate(layout + offset, sizeof(u64));
			coherent = coherent && *reader == pattern;
		}
		*writer = saved;
		::sys_dcache_flush(const_cast<u64*>(writer), sizeof(u64));
		::sys_icache_invalidate(layout + offset, sizeof(u64));
		if (!coherent)
		{
			::vm_deallocate(mach_task_self(), writable_address, static_cast<vm_size_t>(capacity));
			::munmap(layout, total_size);
			set_error("JIT write/execute views do not share instruction bytes");
			return false;
		}
	}

	g_arena.code_allocator.reset(capacity);
	g_arena.data_allocator.reset(capacity);
	g_arena.code = layout;
	g_arena.writable_code = writable_code;
	g_arena.data = layout + capacity;
	g_arena.capacity = capacity;
	g_arena.preparation_chunks = preparation_chunks;
	g_arena.backend = backend;
	g_arena.expanded = expanded;
	g_arena.prepared = true;
	return true;
}
