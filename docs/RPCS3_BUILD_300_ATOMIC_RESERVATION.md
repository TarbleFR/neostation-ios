# RPCS3 Build 300 — atomic JIT reservation

## Device evidence

Build 299 device journals show repeated failed launches with the same boundary:

1. the RPCS3 helper connects;
2. debugserver verifies the correct PID;
3. the final nonce round trip succeeds;
4. `dlopen(libRPCS3Core.dylib)` begins;
5. the process raises `SIGABRT` before the first command-1 JIT preparation request.

Successful launches immediately issue 28 preparation requests of 16 MiB each,
confirming a 448 MiB standard code arena on the tested device. The recovered
frame chain symbolicates to RPCS3's fatal-error path, not to pairing,
LocalDevVPN, game boot, LLVM self-test, or shader compilation.

## Remaining race in Build 299

Build 299 used exact fixed addresses but reserved each candidate through many
independent 16 MiB `vm_allocate` calls. During a fast NeoStation startup, an
unrelated startup thread could map inside a partially owned candidate between
those calls. The Core then discarded the partial reservation and could exhaust
its candidate search from the AsmJIT constructor before any Universal JIT
request became visible.

## Build 300 correction

Each complete code/data candidate is now reserved by one fixed `vm_allocate`
transaction. The already-owned range is changed to `VM_PROT_NONE`, then the
existing bounded `MAP_FIXED` code/data mappings replace only that owned range.

The correction does not add a launch delay, hidden retry, cache deletion,
second `dlopen`, signal suppression, or `VM_FLAGS_OVERWRITE`.
