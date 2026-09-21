# Build 302: targeted RPCS3 startup correction

Build 301 is NOT a device-validated baseline. The active user-validated baseline
remains Build 289 (52acfe7…); main/backup are untouched.

## Memory contract
448 MiB executable code + 576 MiB mutable data = 1 GiB of reserved virtual space.
The 448 MiB RW alias maps the same code pages and is additional virtual address
space, not another allocation of 448 MiB of physical code memory. No promise of
1 GiB physical RAM entitlement, performance, or freedom from all crashes is made.

The host enumerates actual VM gaps and reserves the entire layout BEFORE Core
constructors run. The two ranges must be non-overlapping, page-aligned and within
signed ADRP reach (combined span <= 4 GiB) in the bounded low-VA window. Exact
vm_allocate without overwrite fails on occupied addresses. Either one contiguous
reservation or two verified owned ranges implement the same 448+576 policy.
The Core adopts ownership explicitly; it no longer guesses a second layout.

## Startup lifecycle
One Dart coordinator owns route -> real reservation -> attach -> initialize ->
confirmed helper detach -> actual LLVM execution. Only then is ready published.
On failure, abort is queued AFTER initialize on the native runtime queue. The
helper must be confirmed terminated / not traced before unmapping anything.
The Core permits retry only before persistent AsmJIT/PPU/SPU pointers were
published. After publication a precise restart-required error is retained; no
unsafe retry is allowed. The original failure is always preserved together with
any cleanup failure. An unknown debugger state is never treated as detached.

## Removed misleading behavior
- Deleted the unconditional-success memory preflight.
- Removed the disposable one-page Core readiness probe (the real arena is tested).
- Removed generic restartRequired/JIT-incomplete masking and duplicate single-flight layers.
- Removed credential-reset advice inferred merely from a connection reset.
- Previous helper journals are retained but no longer injected into a new session.
- Each diagnostic record includes PID and host build.

## Source consolidation
A one-time migration materializes the pinned historical NeoStation Core postimage
and the reviewed changes, then records ONE canonical delta and per-file hashes.
The build consumes only this delta; historical generators are no longer executed
by the active RPCS3 build. Their independent old regression fixtures remain for
history, but obsolete stub / allocator tests are replaced by behavior tests.
No unrelated emulator, save, firmware, cache or pairing-file content is changed.

## Validation boundaries
Portable allocator tests inject fragmented maps, races, errors and rollback.
Native Core reset tests execute the actual exported reset body with injected VM
outcomes. macOS tests use the actual session reader / abort method and a real
Darwin 1 GiB reserve/release. Flutter tests verify failures, retry, single flight,
missing evidence, and preservation of original errors. Exact iOS compiler flags
are used for all six modified startup units before the full Core compilation.
Final IPA validation checks binary identities, named direct initializer paths,
required exports, entitlements, icons/resource seal, all three helpers, archive
integrity and SHA-256. None of those tests substitutes for repeated iPhone runs.
