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

	// NEOSTATION_DYNAMIC_JIT_V2: OS-selected addresses, without an application
	// VM tag or fixed-address hint. pthread's MAP_JIT switch is macOS-only in
	// Apple's libpthread. Do not require that SPI or a new entitlement on iOS.
	u8* code = reinterpret_cast<u8*>(MAP_FAILED);
	if (write_protect_function())
	{
		code = static_cast<u8*>(::mmap(nullptr, capacity, PROT_READ | PROT_WRITE | PROT_EXEC,
			MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0));
	}
	const bool uses_pthread = code != MAP_FAILED;
	if (!uses_pthread)
	{
		const int protection = backend == arena_backend::universal_mirrored
			? PROT_READ | PROT_EXEC : PROT_READ | PROT_WRITE;
		code = static_cast<u8*>(::mmap(nullptr, capacity, protection,
			MAP_PRIVATE | MAP_ANON, -1, 0));
	}
	if (code == MAP_FAILED)
	{
		set_error("Unable to allocate dynamic JIT code: " + std::string{std::strerror(errno)});
		return false;
	}

	// Mutable data must remain ordinary RW memory while this thread executes
	// JIT code. Use an address hint, never overwrite an existing host mapping.
	const uptr code_address = reinterpret_cast<uptr>(code);
	auto* const data = static_cast<u8*>(::mmap(reinterpret_cast<void*>(code_address + capacity),
		capacity, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0));
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

	u8* write_view = code;
	if (!uses_pthread)
	{
		// Match DolphiniOS's iOS mapping order: prepare RX, then share that exact
		// prepared object with a writable view. copy=false is essential.
		vm_address_t writable_address = 0;
		vm_prot_t current_protection = VM_PROT_NONE, maximum_protection = VM_PROT_NONE;
		const auto result = ::vm_remap(mach_task_self(), &writable_address, capacity, 0,
			VM_FLAGS_ANYWHERE, mach_task_self(), static_cast<vm_address_t>(code_address),
			false, &current_protection, &maximum_protection, VM_INHERIT_DEFAULT);
		if (result != KERN_SUCCESS)
		{
			::munmap(data, capacity);
			::munmap(code, capacity);
			set_error("Unable to share the prepared dynamic JIT mapping");
			return false;
		}
		write_view = reinterpret_cast<u8*>(writable_address);
		if (::vm_protect(mach_task_self(), writable_address, capacity, false,
			VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS ||
			(backend == arena_backend::legacy_debugger &&
				::mprotect(code, capacity, PROT_READ | PROT_EXEC) != 0))
		{
			::vm_deallocate(mach_task_self(), writable_address, capacity);
			::munmap(data, capacity);
			::munmap(code, capacity);
			set_error("Unable to protect the dynamic JIT execution/write views");
			return false;
		}
		// Catch a detached/COW view before LLVM publishes any function pointer.
		// Check distinct pages and two patterns; restore the original contents.
		for (const usz offset : {usz{0}, capacity / 2, capacity - page_size()})
		{
			auto* const writer = reinterpret_cast<volatile u64*>(write_view + offset);
			auto* const reader = reinterpret_cast<volatile const u64*>(code + offset);
			const u64 saved = *writer;
			bool coherent = true;
			for (const u64 pattern : {u64{0x13579bdf2468ace0}, u64{0xfedcba9876543210}})
			{
				*writer = pattern;
				std::atomic_thread_fence(std::memory_order_seq_cst);
				coherent = coherent && *reader == pattern;
			}
			*writer = saved;
			::sys_dcache_flush(const_cast<u64*>(writer), sizeof(u64));
			::sys_icache_invalidate(code + offset, sizeof(u64));
			if (!coherent)
			{
				::vm_deallocate(mach_task_self(), writable_address, capacity);
				::munmap(data, capacity);
				::munmap(code, capacity);
				set_error("Dynamic JIT write/execute views do not share instruction bytes");
				return false;
			}
		}
	}

	g_arena.code_allocator.reset(capacity);
	g_arena.data_allocator.reset(capacity);
	g_arena.code = code;
	g_arena.write_view = write_view;
	g_arena.data = data;
	g_arena.capacity = capacity;
	g_arena.preparation_chunks = preparation_chunks;
	g_arena.backend = backend;
	g_arena.expanded = expanded;
	g_arena.prepared = true;
	return true;
}
