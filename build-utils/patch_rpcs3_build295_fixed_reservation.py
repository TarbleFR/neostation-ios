#!/usr/bin/env python3
"""Make the iOS JIT low-address reservation deterministic before dlopen.

Build 298 device journals plus symbolication of the exact packaged Core show
failed RPCS3 launches reaching the AsmJIT global-runtime constructor, where
rpcs3::ios::jit::prepare_arena() returns false before the Core can issue its
first command-1 JIT preparation request. That constructor converts the failure
to raw_verify_error -> thread_ctrl::emergency_exit -> report_fatal_error -> abort.
The v0.9-era NeoStation backport reaches that boundary through
reserve_arena_layout(), whose mmap(address, ...) call is only a hint on Darwin.
A hint may be relocated by the kernel; the old code then discards it and can
exhaust every low-VA candidate depending on ASLR. Successful retries reach the
command-1 preparation loop, isolating this pre-command reservation as the
intermittent launch boundary.

Reserve each candidate at the requested Mach address with the iPhoneOS-supported
vm_allocate API. VM_FLAGS_FIXED without VM_FLAGS_OVERWRITE fails on occupied
mappings, so this does not replace
another image, stack, or allocation. This is a Core source correction: there is
no host retry, delay, cache deletion, or second dlopen.
"""
from pathlib import Path
import sys

MARKER = 'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1'

OLD = r'''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
	vm_address_t end = arena_address_end) noexcept
{
	// Reserve the whole candidate without MAP_FIXED. Darwin may treat the
	// requested address as a hint, so accept only an exact result and release
	// every fallback mapping. This never overwrites an occupied dylib/stack
	// range and avoids the Build 266-only load-time dependency on vm_map.
	if (!size || begin < arena_address_begin || end > arena_address_end || begin >= end || size > end - begin)
	{
		return nullptr;
	}

	begin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
	for (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
	{
		void* const mapping = ::mmap(reinterpret_cast<void*>(candidate), size, PROT_NONE,
			MAP_PRIVATE | MAP_ANON, jit_vm_tag, 0);
		if (mapping == MAP_FAILED)
		{
			continue;
		}
		if (mapping == reinterpret_cast<void*>(candidate))
		{
			return static_cast<u8*>(mapping);
		}
		::munmap(mapping, size);
	}
	return nullptr;
}'''

NEW = r'''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
	vm_address_t end = arena_address_end) noexcept
{
	// NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1
	// mmap(address, ...) is only a hint on Darwin and was the last nondeterministic
	// operation before the first Universal JIT BRK. Reserve the requested low-VA
	// range with Mach fixed allocation instead. Do NOT use the overwrite flag:
	// an occupied candidate must fail rather than replace another mapping.
	if (!size || begin < arena_address_begin || end > arena_address_end || begin >= end || size > end - begin)
	{
		return nullptr;
	}

	begin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
	for (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
	{
		usz reserved = 0;
		while (reserved < size)
		{
			const usz length = std::min(size - reserved, rpcs3::ios::jit::arena_prepare_chunk_size);
			vm_address_t address = candidate + reserved;
			const kern_return_t result = ::vm_allocate(
				mach_task_self(),
				&address,
				static_cast<vm_size_t>(length),
				VM_FLAGS_FIXED | jit_vm_tag);
			if (result != KERN_SUCCESS || address != candidate + reserved)
			{
				if (result == KERN_SUCCESS)
				{
					::vm_deallocate(mach_task_self(), static_cast<vm_address_t>(address),
						static_cast<vm_size_t>(length));
				}
				break;
			}
			reserved += length;
		}
		if (reserved == size)
		{
			// Keep the reservation inaccessible until map_arena_region installs
			// the final RX/RW mappings at these exact addresses.
			if (::vm_protect(mach_task_self(), candidate, static_cast<vm_size_t>(size),
				false, VM_PROT_NONE) == KERN_SUCCESS)
			{
				return reinterpret_cast<u8*>(candidate);
			}
		}
		if (reserved)
		{
			::vm_deallocate(mach_task_self(), candidate, static_cast<vm_size_t>(reserved));
		}
	}
	return nullptr;
}'''


def patch(root: Path) -> None:
    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()
    if MARKER in text:
        reservation = text.split('u8* reserve_arena_layout(', 1)[1].split(
            '\nu8* reserve_code_data_layout(', 1
        )[0]
        forbidden_overwrite_forms = (
            'VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE',
            'VM_FLAGS_OVERWRITE | VM_FLAGS_FIXED',
        )
        if ('::vm_allocate(' not in reservation or
                'VM_FLAGS_FIXED | jit_vm_tag' not in reservation or
                any(form in reservation for form in forbidden_overwrite_forms) or
                f'set_error("{MARKER}: Unable to reserve the JIT arena layout' not in text):
            raise RuntimeError('Build 295 reservation marker exists without its exact-allocation contract')
        print('Build 295 fixed JIT reservation already applied and verified')
        return
    if 'NEOSTATION_DYNAMIC_JIT_V5' not in text:
        raise RuntimeError('Build 295 requires the validated Build 266 v0.9-era JIT backport')
    if text.count(OLD) != 1:
        raise RuntimeError(f'Build 295 reservation preimage drift: {text.count(OLD)} matches')
    text = text.replace(OLD, NEW, 1)
    error_old = 'set_error("Unable to reserve the JIT arena layout in low virtual address space (code=" +'
    error_new = f'set_error("{MARKER}: Unable to reserve the JIT arena layout in low virtual address space (code=" +'
    if text.count(error_old) != 1:
        raise RuntimeError(f'Build 295 arena failure-message drift: {text.count(error_old)} matches')
    text = text.replace(error_old, error_new, 1)
    if '#include <mach/mach_vm.h>' in text or '::mach_vm_allocate(' in text:
        raise RuntimeError('Build 295 must use the iPhoneOS-supported vm_allocate API')
    forbidden_overwrite_forms = (
        'VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE',
        'VM_FLAGS_OVERWRITE | VM_FLAGS_FIXED',
    )
    if any(form in NEW for form in forbidden_overwrite_forms):
        raise RuntimeError('Build 295 must never overwrite an occupied VM mapping')
    path.write_text(text)
    print('Build 295: deterministic fixed low-VA JIT reservation applied')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_build295_fixed_reservation.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]).resolve())