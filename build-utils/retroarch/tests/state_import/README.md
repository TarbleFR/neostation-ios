# Portable state import behavior checks

Run from the repository root with a pristine checkout of the frontend revision
recorded in `build-utils/retroarch/source.json`:

```sh
python3 build-utils/retroarch/run_state_import_checks.py --upstream /path/to/RetroArch
python3 build-utils/retroarch/run_state_import_checks.py --upstream /path/to/RetroArch --sanitizers address,undefined
```

The runner compiles the production `NeoRetroArchStateImport.c` with the genuine
pinned `rzip_stream.c` and `trans_stream_zlib.c`. It extracts
`content_load_rastate1` and `content_deserialize_state` without changing their
bodies, using the balanced parser in `prepare_source.py`. A recording core checks
the exact unserialized payload and rejects states from an incompatible core.
The genuine RZIP writer creates valid compressed fixtures, including multiple
chunks. Crafted fixtures exercise malformed headers, block lengths, truncated
deflate streams and decoded size limits. Every opened file must close and every
existing input file must retain its original SHA-256 after success or failure.

`posix_file_stream.c` provides harness-only filesystem adapters and chooses the
real zlib backend objects. An allocation hook applied only to the production
helper verifies that rejected sizes never allocate a decoded buffer and that a
failed allocation closes the stream. Upstream decoder sources remain unchanged.
Every allocated decoded buffer must be freed exactly once, including read and
core rejection failures.
Temporary compilation and fixtures are removed automatically. `--report` saves
the exact source identities and individual results when desired.

These checks verify file decoding, parser bounds, core handoff, resource cleanup
and preservation of imported files on the host. They do not qualify any actual
emulator core, iPhone, renderer, or App Store release.

Some restricted hosts block LeakSanitizer's access to `/proc`. In that case an
explicit `ASAN_OPTIONS=detect_leaks=0:halt_on_error=1` can disable only leak
scanning while keeping AddressSanitizer and UndefinedBehaviorSanitizer active.
The report records those options, and the buffer/stream lifetime assertions
remain mandatory.
