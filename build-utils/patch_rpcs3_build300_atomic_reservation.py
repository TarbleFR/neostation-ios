#!/usr/bin/env python3
"""Remove the remaining launch-time race from the iOS JIT reservation.

Build 299 device journals show the same deterministic failure boundary on every
failed launch: the debugger nonce completes, dlopen enters RPCS3Core, then the
Core aborts with SIGABRT before the first command-1 JIT preparation request.
Successful launches immediately prepare 28 x 16 MiB code chunks (448 MiB).

Build 295 made every address exact, but it still reserved one candidate through
many independent 16 MiB vm_allocate calls. During a fast NeoStation startup,
other threads can create a mapping between those calls. The partially reserved
candidate is then discarded and the AsmJIT constructor can exhaust its search
before any Universal JIT request is visible.

Reserve the complete candidate with one fixed vm_allocate transaction, then
change that already-owned range to VM_PROT_NONE. The later MAP_FIXED mappings
remain safe because they replace only the range owned by this process. No retry,
delay, cache deletion, signal suppression, or overwrite flag is introduced.
"""
from pathlib import Path
import sys

MARKER = 'NEOSTATION_BUILD300_ATOMIC_JIT_RESERVATION_V1'
PREVIOUS_MARKER = 'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1'

OLD = r'''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
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
	// NEOSTATION_BUILD300_ATOMIC_JIT_RESERVATION_V1
	// Reserve the complete candidate in one kernel transaction. Build 299 still
	// used one fixed allocation per 16 MiB preparation chunk, leaving a race in
	// which another startup thread could map inside a partially owned candidate.
	// Do NOT use VM_FLAGS_OVERWRITE: occupied candidates must remain untouched.
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

		// The whole candidate is already owned, so later MAP_FIXED code/data
		// mappings cannot race with unrelated process mappings inside this range.
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
        raise RuntimeError('Build 300 atomic reservation marker is missing')
    if reservation.count('::vm_allocate(') != 1:
        raise RuntimeError('Build 300 must use one vm_allocate call per candidate')
    if 'static_cast<vm_size_t>(size)' not in reservation:
        raise RuntimeError('Build 300 must reserve the complete candidate size')
    if 'while (reserved < size)' in reservation or 'candidate + reserved' in reservation:
        raise RuntimeError('Build 300 retained the chunk-by-chunk reservation race')
    if 'arena_prepare_chunk_size' in reservation:
        raise RuntimeError('Build 300 reservation must be independent of preparation chunks')
    if any(form in reservation for form in forbidden_overwrite_forms):
        raise RuntimeError('Build 300 must never overwrite an occupied mapping')
    if '::vm_protect(' not in reservation or 'VM_PROT_NONE' not in reservation:
        raise RuntimeError('Build 300 must seal the owned candidate before mapping it')
    if '::vm_deallocate(' not in reservation:
        raise RuntimeError('Build 300 must release failed candidates')
    if f'set_error("{MARKER}: Unable to reserve the JIT arena layout' not in text:
        raise RuntimeError('Build 300 failure identity is missing')


def patch(root: Path) -> None:
    path = root / 'Utilities/JITIOS.cpp'
    text = path.read_text()
    if MARKER in text:
        validate_atomic(text)
        print('Build 300 atomic JIT reservation already applied and verified')
        return
    if PREVIOUS_MARKER not in text:
        raise RuntimeError('Build 300 requires the validated Build 295 exact reservation')
    if text.count(OLD) != 1:
        raise RuntimeError(f'Build 300 reservation preimage drift: {text.count(OLD)} matches')
    text = text.replace(OLD, NEW, 1)
    error_old = f'set_error("{PREVIOUS_MARKER}: Unable to reserve the JIT arena layout in low virtual address space (code=" +'
    error_new = f'set_error("{MARKER}: Unable to reserve the JIT arena layout in low virtual address space (code=" +'
    if text.count(error_old) != 1:
        raise RuntimeError(f'Build 300 arena failure-message drift: {text.count(error_old)} matches')
    text = text.replace(error_old, error_new, 1)
    validate_atomic(text)
    path.write_text(text)
    print('Build 300: atomic full-range low-VA JIT reservation applied')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_build300_atomic_reservation.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]).resolve())
