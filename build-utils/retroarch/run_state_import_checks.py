#!/usr/bin/env python3
"""Exercise the production state importer with pinned, genuine RetroArch decoders.

This is a portable file/decoder check, not an iOS core or device qualification.
No generated source or fixture is written to the repository.
"""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
HARNESS = HERE / "tests/state_import"
MAXIMUM = 128 * 1024 * 1024
RESULTS = {"ok": 0, "open": 1, "size": 2, "codec": 3,
           "read": 4, "allocation": 5, "deserialize": 6}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def extract_content(source, output):
    spec = importlib.util.spec_from_file_location("retroarch_prepare", HERE / "prepare_source.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    text = source.read_text()
    functions = []
    for signature in ("static bool content_load_rastate1(unsigned char* input, size_t len)",
                      "bool content_deserialize_state(const void *s, size_t len)"):
        _, end = module.body_range(text, signature)
        functions.append(text[text.index(signature):end])
    # Definitions used by the extracted parser are taken from the same source.
    constants = []
    for name in ("RASTATE_MEM_BLOCK", "RASTATE_END_BLOCK", "CONTENT_ALIGN_SIZE"):
        matches = [line for line in text.splitlines() if line.startswith("#define " + name)]
        if len(matches) != 1:
            raise ValueError(f"Ambiguous upstream parser constant: {name}")
        constants.append(matches[0])
    output.write_text(
        '/* Test-only extraction of unchanged functions from pinned task_save.c. */\n'
        '#include <stdint.h>\n#include <stdio.h>\n#include <string.h>\n#include "core.h"\n'
        '#define RARCH_ERR(...) fprintf(stderr, __VA_ARGS__)\n'
        '#define RARCH_LOG(...) fprintf(stderr, __VA_ARGS__)\n' +
        "\n".join(constants + functions) + "\n")


def compile_harness(upstream, work, compiler, sanitizers):
    generated = work / "content_parser.c"
    extract_content(upstream / "tasks/task_save.c", generated)
    sources = [
        ROOT / "native/retroarch/NeoRetroArchStateImport.c",
        HARNESS / "posix_file_stream.c", HARNESS / "recording_core.c", generated,
        upstream / "libretro-common/streams/rzip_stream.c",
        upstream / "libretro-common/streams/trans_stream_zlib.c",
    ]
    flags = ["-std=c11", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
             "-D_POSIX_C_SOURCE=200809L", "-DHAVE_ZLIB=1",
             "-I", str(upstream), "-I", str(upstream / "libretro-common/include"),
             "-I", str(ROOT / "native/retroarch")]
    if sanitizers != "none":
        flags += ["-fsanitize=" + sanitizers, "-fno-omit-frame-pointer"]
    objects = []
    for index, source in enumerate(sources):
        obj = work / f"source-{index}.o"
        specific = []
        if source.name == "NeoRetroArchStateImport.c":
            specific = ["-include", str(HARNESS / "allocation_hooks.h"),
                        "-Dmalloc=neo_state_import_test_malloc", "-Dfree=neo_state_import_test_free"]
        elif source == generated:
            # GCC does not recognize upstream's "fall-through intentional"
            # comment. Keep that source body unchanged and scope the warning
            # exception to this translation unit.
            specific = ["-Wno-implicit-fallthrough"]
        subprocess.run([compiler, *flags, *specific, "-c", str(source), "-o", str(obj)], check=True)
        objects.append(str(obj))
    executable = work / "state_import_check"
    subprocess.run([compiler, *flags, *objects, "-lz", "-o", str(executable)], check=True)
    return executable, sources


def rastate(payload, unknown=False):
    blocks = b""
    if unknown:
        blocks += b"TEST" + struct.pack("<I", 3) + b"abc" + b"\0" * 5
    return (b"RASTATE\x01" + blocks + b"MEM " + struct.pack("<I", len(payload)) +
            payload + b"\0" * (-len(payload) % 8) + b"END " + b"\0" * 4)


def rzip_header(total, chunk=131072, version=1):
    return b"#RZIPv" + bytes([version]) + b"#" + struct.pack("<IQ", chunk, total)


def run_cases(executable, work):
    cases = []
    environment = dict(os.environ)
    environment.setdefault("ASAN_OPTIONS", "detect_leaks=1:halt_on_error=1")
    environment.setdefault("UBSAN_OPTIONS", "halt_on_error=1:print_stacktrace=1")

    def fixture(name, data):
        path = work / name
        path.write_bytes(data)
        return path

    payload = bytes((index * 37 + 11) % 256 for index in range(4099))
    raw = fixture("selected-core-raw.state", payload)
    incompatible = fixture("incompatible-core-raw.state", b"different core state" * 70)
    container = fixture("valid-rastate.state", rastate(payload))
    auxiliary = fixture("valid-rastate-auxiliary.state", rastate(payload, unknown=True))

    def check(name, path, expected_result, calls=0, expected=raw, limit=MAXIMUM,
              allocations=None, refuse_allocation=False):
        file_path = path if isinstance(path, Path) else None
        before = sha256(file_path) if file_path and file_path.exists() else None
        process = subprocess.run(
            [str(executable), "import", str(path), str(expected) if expected else "-",
             str(limit), str(int(refuse_allocation))], text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment)
        if process.returncode:
            raise AssertionError(f"{name}: harness exited {process.returncode}: {process.stderr}")
        result = json.loads(process.stdout)
        if result["result"] != RESULTS[expected_result] or result["coreCalls"] != calls:
            raise AssertionError(f"{name}: unexpected result {result}; {process.stderr}")
        if result["openFiles"] != 0:
            raise AssertionError(f"{name}: file stream retained {result}")
        if result["activeAllocations"] != 0:
            raise AssertionError(f"{name}: decoded buffer retained {result}")
        if not refuse_allocation and result["frees"] != result["allocations"]:
            raise AssertionError(f"{name}: decoded buffer not released exactly once {result}")
        if allocations is not None and result["allocations"] != allocations:
            raise AssertionError(f"{name}: unexpected decoded allocations {result}")
        if result["largestAllocation"] > limit:
            raise AssertionError(f"{name}: allocation exceeds caller bound {result}")
        if before is not None and sha256(file_path) != before:
            raise AssertionError(f"{name}: imported source file was modified")
        cases.append({"name": name, **result, "sourceFileUnchanged": before is not None})

    check("raw core state", raw, "ok", 1, allocations=1)
    check("RASTATE1 core block", container, "ok", 1, allocations=1)
    check("RASTATE1 unknown auxiliary block", auxiliary, "ok", 1, allocations=1)
    check("selected core rejects incompatible raw state", incompatible, "deserialize", 1, allocations=1)
    check("selected core rejects incompatible RASTATE1 state",
          fixture("incompatible-rastate.state", rastate(incompatible.read_bytes())),
          "deserialize", 1, allocations=1)
    check("unavailable file", work / "missing.state", "open", allocations=0)
    check("null path", "<null>", "size", allocations=0)
    check("empty path", "", "size", allocations=0)
    check("caller bound below identifier", raw, "size", limit=7, allocations=0)
    check("raw caller bound exceeded", raw, "size", limit=len(payload)-1, allocations=0)
    check("raw caller bound exact", raw, "ok", 1, limit=len(payload), allocations=1)
    minimum = fixture("minimum.state", b"coredata")
    check("eight byte raw minimum", minimum, "ok", 1, expected=minimum, limit=8, allocations=1)
    check("decoded allocation failure", raw, "allocation", allocations=1, refuse_allocation=True)
    check("empty input", fixture("empty.state", b""), "read", allocations=0)
    for length in range(1, 8):
        check(f"raw truncated to {length} bytes", fixture(f"short-{length}.state", b"x" * length),
              "size", allocations=0)
    for length in range(8, 16):
        check(f"RASTATE1 truncated to {length} bytes",
              fixture(f"rastate-truncated-{length}.state", container.read_bytes()[:length]),
              "deserialize", allocations=1)
    check("unknown RASTATE version", fixture("rastate-version.state", b"RASTATE\x02" + b"\0" * 16),
          "deserialize", allocations=1)
    check("RASTATE1 oversized core block", fixture("rastate-block-overflow.state",
          b"RASTATE\x01MEM " + struct.pack("<I", 0xFFFFFFFF) + b"x" * 16),
          "deserialize", allocations=1)
    check("RASTATE1 missing core block", fixture("rastate-no-core.state", b"RASTATE\x01END " + b"\0" * 4),
          "deserialize", allocations=1)
    check("RASTATE1 incomplete core payload", fixture("rastate-short-payload.state",
          b"RASTATE\x01MEM " + struct.pack("<I", len(payload)) + payload[:-1]),
          "deserialize", allocations=1)

    for name, input_path in (("raw", raw), ("rastate", container)):
        compressed = work / f"genuine-{name}.rzip"
        subprocess.run([str(executable), "encode", str(input_path), str(compressed)],
                       check=True, env=environment)
        check(f"genuine RZIP deflate {name}", compressed, "ok", 1, allocations=1)
        encoded = compressed.read_bytes()
        check(f"RZIP {name} physical truncation", fixture(f"truncated-{name}.rzip", encoded[:-1]),
              "read", allocations=1)
    # Exercise the real writer/reader across the 128 KiB chunk boundary.
    large_payload = payload * 65
    large_raw = fixture("multi-chunk-raw.state", large_payload)
    multi = work / "genuine-multi-chunk.rzip"
    subprocess.run([str(executable), "encode", str(large_raw), str(multi)],
                   check=True, env=environment)
    check("genuine RZIP deflate multiple chunks", multi, "ok", 1, expected=large_raw, allocations=1)

    check("unknown RZIP codec", fixture("rzip-version.rzip", rzip_header(len(payload), version=3)),
          "codec", allocations=0)
    check("uncompiled RZIP Zstandard codec", fixture("rzip-zstd.rzip", rzip_header(len(payload), version=2)),
          "codec", allocations=0)
    check("RZIP header truncated", fixture("rzip-short-header.rzip", rzip_header(len(payload))[:19]),
          "read", allocations=0)
    check("RZIP invalid terminator", fixture("rzip-magic.rzip", b"#RZIPv\x01!" + b"\0" * 12),
          "read", allocations=0)
    for value, name in ((0, "zero"), (MAXIMUM + 1, "above 128 MiB"), (2**64-1, "uint64 maximum")):
        check(f"RZIP decoded size {name}", fixture(f"rzip-size-{value}.rzip", rzip_header(value)),
              "size", allocations=0)
    for value, name in ((0, "zero"), (4 * 1024 * 1024 + 1, "above 4 MiB"), (2**32-1, "uint32 maximum")):
        check(f"RZIP chunk size {name}", fixture(f"rzip-chunk-{value}.rzip", rzip_header(len(payload), value)),
              "size", allocations=0)
    sparse = work / "raw-oversize.state"
    with sparse.open("wb") as file:
        file.truncate(MAXIMUM + 1)
    check("raw decoded size above 128 MiB", sparse, "size", allocations=0)
    compressed = zlib.compress(payload)
    check("RZIP corrupt deflate", fixture("rzip-corrupt.rzip", rzip_header(len(payload)) +
          struct.pack("<I", len(compressed)) + b"x" * len(compressed)), "read", allocations=1)
    check("RZIP oversized compressed chunk", fixture("rzip-compressed-oversize.rzip",
          rzip_header(len(payload)) + struct.pack("<I", 2**32-1)), "read", allocations=1)
    check("RZIP incomplete deflate stream with matching physical size", fixture("rzip-incomplete-deflate.rzip",
          rzip_header(len(payload)) + struct.pack("<I", len(compressed)-2) + compressed[:-2]),
          "read", allocations=1)
    check("RZIP decoded size exceeds actual payload", fixture("rzip-decoded-mismatch.rzip",
          rzip_header(len(payload)+1) + struct.pack("<I", len(compressed)) + compressed),
          "read", allocations=1)
    return cases


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    parser.add_argument("--cc", default=os.environ.get("CC", "cc"))
    parser.add_argument("--sanitizers", choices=("none", "undefined", "address,undefined"), default="none")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    pinned = json.loads((HERE / "source.json").read_text())["frontend"]["commit"]
    actual = subprocess.check_output(["git", "-C", str(args.upstream), "rev-parse", "HEAD"], text=True).strip()
    if actual != pinned:
        raise ValueError(f"Frontend source mismatch: {actual}; expected {pinned}")
    changed = subprocess.check_output(["git", "-C", str(args.upstream), "status", "--porcelain",
                                       "--untracked-files=no"], text=True)
    if changed.strip():
        raise ValueError("Upstream checkout has modified tracked files")
    compiler = shutil.which(args.cc)
    if not compiler:
        raise ValueError(f"C compiler not available: {args.cc}")
    with tempfile.TemporaryDirectory(prefix="neo-state-import-") as directory:
        work = Path(directory)
        executable, sources = compile_harness(args.upstream, work, compiler, args.sanitizers)
        cases = run_cases(executable, work)
        source_hashes = {str(path.relative_to(args.upstream)): sha256(path)
                         for path in sources if path.is_relative_to(args.upstream)}
    result = {"frontendCommit": pinned, "productionHelperSha256": sha256(ROOT / "native/retroarch/NeoRetroArchStateImport.c"),
              "decoderSourceSha256": source_hashes,
              "taskSaveSourceSha256": sha256(args.upstream / "tasks/task_save.c"),
              "genuineDecoder": True, "sanitizers": args.sanitizers,
              "addressSanitizerOptions": os.environ.get("ASAN_OPTIONS", "detect_leaks=1:halt_on_error=1"),
              "checksPassed": len(cases), "deviceQualified": False, "checks": cases}
    if args.report:
        args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
