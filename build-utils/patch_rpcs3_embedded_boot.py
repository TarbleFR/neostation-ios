#!/usr/bin/env python3
"""Apply reviewed boot fixes to NeoStation's pinned, embedded RPCS3 Core."""
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str) -> str:
    if new in text:
        return text
    if text.count(old) != 1:
        raise ValueError(f"Pinned source mismatch: {old[:100]!r}")
    return text.replace(old, new, 1)


def patch(root: Path) -> None:
    edits = {}
    spu = root / 'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp'
    text = spu.read_text()
    text = replace_once(text, '\t// Read cache\n\tauto func_list = cache.get();', '''\t// NEOSTATION_EMBEDDED_SPU_ON_DEMAND
\t// LLVM Precompilation previously disabled only *new* SPU precompilation.
\t// Existing raw SPU caches were still recompiled in full on every launch.
\t// ARM64 cannot reuse their machine objects across processes (host pointers),
\t// so honour the mobile on-demand policy for warm launches as well.
\t// Leave the cache on disk. Do not append duplicates to an unread cache.
#ifdef RPCS3_IOS
\tconst bool defer_existing_spu_cache = !g_cfg.core.llvm_precompilation;
#else
\tconstexpr bool defer_existing_spu_cache = false;
#endif
\tauto func_list = defer_existing_spu_cache ? std::deque<spu_program>{} : cache.get();
\tif (defer_existing_spu_cache)
\t{
\t\tspu_log.notice("NeoStation: SPU cache warmup deferred; LLVM compiles blocks on demand; disk cache retained.");
\t}''')
    text = replace_once(text,
        '\tif (g_cfg.core.spu_cache && !spu_precompilation_enabled && cache)',
        '\tif (g_cfg.core.spu_cache && !spu_precompilation_enabled && cache && !defer_existing_spu_cache)')
    edits[spu] = text

    ppu = root / 'rpcs3/Emu/Cell/PPUThread.cpp'
    text = ppu.read_text()
    text = replace_once(text,
        '\t\t\tfmt::append(obj_name, "v8-kusa-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));',
        '''#ifdef RPCS3_IOS
\t\t\t// Separate this source-built Core's LLVM objects from earlier IPA cores.
\t\t\t// Preserve old files; only recompile incompatible objects once.
\t\t\tfmt::append(obj_name, "v8-neostation-embedded1-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));
#else
\t\t\tfmt::append(obj_name, "v8-kusa-%s-%s-%s.obj", fmt::base57(output, 16), fmt::base57(settings), jit_compiler::cpu(g_cfg.core.llvm_cpu.to_string()));
#endif''')
    text = replace_once(text,
        '\t\t\tif (!failed_to_load && !jits[mod_index / c_modules_per_jit]->add(cache_path + obj_name))',
        '''#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU link begin: %s", obj_name);
#endif
\t\t\tif (!failed_to_load && !jits[mod_index / c_modules_per_jit]->add(cache_path + obj_name))''')
    text = replace_once(text,
        '\t\t\tjit->fin();',
        '''#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU relocation begin");
#endif
\t\t\tjit->fin();
#ifdef RPCS3_IOS
\t\t\tppu_log.notice("NeoStation PPU relocation complete");
#endif''')
    edits[ppu] = text

    api = root / 'rpcs3/ios/RPCS3IOS.cpp'
    text = api.read_text()
    text = replace_once(text,
        '''\tboot_progress_snapshot snapshot = read();
\tfor (;;)
\t{
\t\tboot_progress_snapshot next = read();
\t\tif (next == snapshot)
\t\t{
\t\t\treturn snapshot;
\t\t}
\t\tsnapshot = std::move(next);
\t}''',
        '''\tboot_progress_snapshot snapshot = read();
\t// A diagnostic reader must not spin indefinitely while workers advance.
\tfor (u32 attempt = 0; attempt < 8; ++attempt)
\t{
\t\tboot_progress_snapshot next = read();
\t\tif (next == snapshot)
\t\t{
\t\t\treturn snapshot;
\t\t}
\t\tsnapshot = std::move(next);
\t}
\treturn snapshot;''')
    edits[api] = text
    # Validate every replacement before modifying the checkout.
    for path, text in edits.items():
        path.write_text(text)
        print(f'Patched {path.relative_to(root)}')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: patch_rpcs3_embedded_boot.py <pinned-rpcs3-source>')
    patch(Path(sys.argv[1]))
