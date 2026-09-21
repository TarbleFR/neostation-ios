#!/usr/bin/env python3
"""Keep one exact low-VA arena reservation, then install deferred RPCS3 JIT init.

Build 298 proved that mmap(address, ...) was only a hint on Darwin. Build 299
still owned a candidate through several chunk allocations. The reservation below
uses one fixed vm_allocate transaction without overwrite. It has no host retry,
artificial delay or cache deletion. The companion patch then makes dlopen passive;
the arena is not touched until rpcs3_ios_initialize().
"""
from __future__ import annotations

from pathlib import Path
import importlib.util
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

CHUNKED = r'''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
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

NEW = r'''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
	vm_address_t end = arena_address_end) noexcept
{
	// NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1
	// Reserve the complete candidate in one kernel transaction. Splitting the
	// reservation into preparation-sized chunks left a launch-time race with
	// unrelated startup mappings. Do NOT use the overwrite flag.
	if (!size || begin < arena_address_begin || end > arena_address_end || begin >= end || size > end - begin)
	{
		return nullptr;
	}

	begin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
	for (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
	{
		vm_address_t address = candidate;
		const kern_return_t result = ::vm_allocate(
			mach_task_self(),
			&address,
			static_cast<vm_size_t>(size),
			VM_FLAGS_FIXED | jit_vm_tag);
		if (result != KERN_SUCCESS || address != candidate)
		{
			if (result == KERN_SUCCESS)
			{
				::vm_deallocate(mach_task_self(), address, static_cast<vm_size_t>(size));
			}
			continue;
		}

		// The complete range is already owned, so the later MAP_FIXED code/data
		// mappings cannot race with an unrelated mapping inside this candidate.
		if (::vm_protect(mach_task_self(), candidate, static_cast<vm_size_t>(size),
			false, VM_PROT_NONE) == KERN_SUCCESS)
		{
			return reinterpret_cast<u8*>(candidate);
		}
		::vm_deallocate(mach_task_self(), candidate, static_cast<vm_size_t>(size));
	}
	return nullptr;
}'''


def reservation_body(text: str) -> str:
    return text.split('u8* reserve_arena_layout(', 1)[1].split(
        '\nu8* reserve_code_data_layout(', 1
    )[0]


def validate_atomic(text: str) -> None:
    reservation = reservation_body(text)
    forbidden_overwrite_forms = (
        'VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE',
        'VM_FLAGS_OVERWRITE | VM_FLAGS_FIXED',
    )
    if MARKER not in reservation:
        raise RuntimeError('Build 295 reservation marker is missing')
    if reservation.count('::vm_allocate(') != 1:
        raise RuntimeError('Build 295 must use exactly one vm_allocate call per candidate')
    if 'static_cast<vm_size_t>(size)' not in reservation:
        raise RuntimeError('Build 295 must reserve the complete candidate size')
    if 'while (reserved < size)' in reservation or 'candidate + reserved' in reservation:
        raise RuntimeError('Build 295 retained the chunk-by-chunk reservation race')
    if 'arena_prepare_chunk_size' in reservation:
        raise RuntimeError('Reservation ownership must not depend on preparation chunks')
    if any(form in reservation for form in forbidden_overwrite_forms):
        raise RuntimeError('Build 295 must never overwrite an occupied mapping')
    if '::vm_protect(' not in reservation or 'VM_PROT_NONE' not in reservation:
        raise RuntimeError('Build 295 must protect the fully owned candidate')
    if '::vm_deallocate(' not in reservation:
        raise RuntimeError('Build 295 must release failed candidates')
    if f'set_error("{MARKER}: Unable to reserve the JIT arena layout' not in text:
        raise RuntimeError('Build 295 failure identity is missing')


def patch(root: Path) -> None:
    """Patch only the reservation. Kept separate for the focused unit fixture."""
    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()

    if MARKER in text:
        try:
            validate_atomic(text)
        except RuntimeError:
            if text.count(CHUNKED) != 1:
                raise
            text = text.replace(CHUNKED, NEW, 1)
            validate_atomic(text)
            path.write_text(text)
            print('Build 295 chunked reservation upgraded to one atomic transaction')
            return
        print('Build 295 atomic fixed JIT reservation already applied and verified')
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
    validate_atomic(text)
    path.write_text(text)
    print('Build 295: atomic exact low-VA JIT reservation applied')


def _load_deferred_module():
    script = Path(__file__).resolve().parent / 'rpcs3' / 'deferred_jit_init.py'
    spec = importlib.util.spec_from_file_location('neostation_deferred_jit_init', script)
    if spec is None or spec.loader is None:
        raise RuntimeError(f'Unable to load deferred JIT patch: {script}')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def patch_complete(root: Path) -> None:
    patch(root)
    _load_deferred_module().patch(root)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_build295_fixed_reservation.py <pinned-rpcs3-source>')
    patch_complete(Path(sys.argv[1]).resolve())
