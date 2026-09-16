#!/usr/bin/env python3
"""Backport selected XITRIX v0.9-era JIT/progress changes onto Build 265.

The original RPCS3 commit/ABI, NeoStation's patches and user caches are retained.
The backport source is immutable and independently SHA-256 checked. Pre/post
hashes fail closed if the preceding patch chain or upstream bytes drift.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REVISION = '505a85e5a8f2cdff1cd63168bd2c56b0f92282bf'
JIT_MARKER = 'NEOSTATION_DYNAMIC_JIT_V5'
BUILD_MARKER = 'NEOSTATION_BUILD266_JIT_V09_SHADER_V1'
SHADER_CHECKPOINT_MARKER = 'NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1'
MANIFEST = ROOT / 'build-utils/rpcs3/build266-v09-manifest.json'
COPIED = (
    'Utilities/JITIOS.cpp', 'Utilities/JITIOS.h', 'Utilities/JITIOSLayoutPolicy.h',
    'Utilities/JITASM.cpp', 'Utilities/JITLLVM.cpp', 'rpcs3/ios/RPCS3IOSContract.h',
    'rpcs3/Emu/system_progress.cpp', 'rpcs3/ios/RPCS3IOS.h',
    'rpcs3/ios/tests/JITArenaAllocatorTests.cpp',
    'rpcs3/ios/tests/NativeProgressCompletionTests.cpp',
)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def function(text: str, signature: str) -> str:
    start = text.index(signature)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def patch(source: Path, upstream_source: Path | None = None) -> None:
    manifest = json.loads(MANIFEST.read_text())
    targets = manifest['targets']
    current = {name: (source / name).read_bytes() if (source / name).is_file() else None
               for name in targets}
    hashes = {name: digest(data) if data is not None else None for name, data in current.items()}
    if all(hashes[name] == entry['after'] for name, entry in targets.items()):
        print('Build 266 JIT/progress/shader checkpoint already applied and verified')
        return
    for name, entry in targets.items():
        if hashes[name] != entry['before']:
            raise RuntimeError(f'Build 266 preimage mismatch: {name}')

    if upstream_source is None:
        found = subprocess.run(['git', '-C', str(source), 'cat-file', '-e', REVISION],
                               capture_output=True, check=False)
        if found.returncode:
            subprocess.run(['git', '-C', str(source), 'fetch', '--depth', '1',
                            'https://github.com/XITRIX/rpcs3.git', REVISION], check=True)
    upstream: dict[str, str] = {}
    for name, expected in manifest['upstream_sha256'].items():
        data = ((upstream_source / name).read_bytes() if upstream_source else
                subprocess.check_output(['git', '-C', str(source), 'show', f'{REVISION}:{name}']))
        if digest(data) != expected:
            raise RuntimeError(f'Build 266 upstream checksum mismatch: {name}')
        upstream[name] = data.decode('utf-8')
    updated = {name: data.decode('utf-8') if data is not None else '' for name, data in current.items()}
    for name in COPIED:
        updated[name] = upstream[name]

    # The v0.9 source adds direct imports of vm_map and os_log helpers that are
    # absent from the known-good V4 Core.
    # Build 266 device logs show dyld terminating while dlopen resolves the Core,
    # before rpcs3_ios_initialize or any arena code can run. Keep the v0.9
    # low-address policy, but reserve exact non-overwriting ranges with mmap --
    # a public primitive already used by the proven V4 Core -- and leave early
    # errors in g_last_error for the host instead of importing os_log internals.
    jit_ios = updated['Utilities/JITIOS.cpp']
    jit_ios = jit_ios.replace('#include <os/log.h>\n', '')
    jit_ios = jit_ios.replace(
        '\t// Core constructors can fail before the frontend log callback is installed.\n'
        '\tos_log_error(OS_LOG_DEFAULT, "RPCS3 JIT: %{public}s", message.c_str());\n',
        '')
    upstream_reservation = function(jit_ios, 'u8* reserve_arena_layout(')
    safe_reservation = '''u8* reserve_arena_layout(usz size, vm_address_t begin = arena_address_begin,
\tvm_address_t end = arena_address_end) noexcept
{
\t// Reserve the whole candidate without MAP_FIXED. Darwin may treat the
\t// requested address as a hint, so accept only an exact result and release
\t// every fallback mapping. This never overwrites an occupied dylib/stack
\t// range and avoids the Build 266-only load-time dependency on vm_map.
\tif (!size || begin < arena_address_begin || end > arena_address_end || begin >= end || size > end - begin)
\t{
\t\treturn nullptr;
\t}

\tbegin = (begin + arena_address_step - 1) & ~(arena_address_step - 1);
\tfor (vm_address_t candidate = begin; candidate <= end - size; candidate += arena_address_step)
\t{
\t\tvoid* const mapping = ::mmap(reinterpret_cast<void*>(candidate), size, PROT_NONE,
\t\t\tMAP_PRIVATE | MAP_ANON, jit_vm_tag, 0);
\t\tif (mapping == MAP_FAILED)
\t\t{
\t\t\tcontinue;
\t\t}
\t\tif (mapping == reinterpret_cast<void*>(candidate))
\t\t{
\t\t\treturn static_cast<u8*>(mapping);
\t\t}
\t\t::munmap(mapping, size);
\t}
\treturn nullptr;
}'''
    jit_ios = jit_ios.replace(upstream_reservation, safe_reservation)
    if '#include <os/log.h>' in jit_ios or 'os_log_error(' in jit_ios or '::vm_map(' in jit_ios:
        raise RuntimeError('Build 266 retained a forbidden load-time JIT import')
    updated['Utilities/JITIOS.cpp'] = jit_ios

    # Preserve the existing shared RW/RX proof; the upstream allocator alone
    # does not demonstrate that its writable alias is coherent with RX pages.
    original = (ROOT / 'build-utils/rpcs3/jit_arena.cpp.inc').read_text()
    start = original.index('\t// Prove that the final write and execute views')
    end = original.index('\n\tg_arena.code_allocator.reset', start)
    proof = original[start:end].replace('writable_code + offset', 'reinterpret_cast<u8*>(alias) + offset')
    proof = proof.replace(
        '::vm_deallocate(mach_task_self(), writable_address, static_cast<vm_size_t>(capacity));\n\t\t\t::munmap(layout, total_size);',
        'discard_layout(layout, capacity, data, data_capacity, alias);')
    updated['Utilities/JITIOS.cpp'] = updated['Utilities/JITIOS.cpp'].replace(
        '\tg_arena.code_allocator.reset(capacity);',
        f'\t// {JIT_MARKER}: low-VA code/data plus shared-alias proof.\n' +
        proof + '\n\tg_arena.code_allocator.reset(capacity);')

    api = updated['rpcs3/ios/RPCS3IOS.cpp']
    api = api.replace(function(api, 'void emit_jit_arena_statistics('),
                      function(upstream['rpcs3/ios/RPCS3IOS.cpp'], 'void emit_jit_arena_statistics('))
    api = api.replace('prepare_arena(config->expanded_jit_arena != 0)',
                      'prepare_arena(config->expanded_jit_arena)')
    api = api.replace('NEOSTATION_DYNAMIC_JIT_V4', JIT_MARKER)
    api = api.replace('contiguous debugger-prepared RX/RW arena verified',
                      'low-address debugger-prepared RX/RW arena verified')
    api = api.replace('\\"lto\\":',
                      f'\\"build266\\":\\"{BUILD_MARKER}\\",'
                      f'\\"jit_backport\\":\\"{REVISION}\\",\\"lto\\":')
    updated['rpcs3/ios/RPCS3IOS.cpp'] = api

    device = 'rpcs3/Emu/RSX/VK/vkutils/device.h'
    updated[device] = updated[device].replace('\t\tvoid destroy();',
        '\t\tvoid destroy();\n#ifdef RPCS3_IOS\n'
        '\t\t// Call only after cached-shader workers have joined, before gameplay.\n'
        '\t\tvoid checkpoint_pipeline_cache() const { save_pipeline_cache(); }\n#endif')
    render = 'rpcs3/Emu/RSX/VK/VKGSRender.cpp'
    body = function(updated[render], 'void VKGSRender::on_init_thread()')
    replacement = body[:-2] + '''
#ifdef RPCS3_IOS
	// NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1
	// load() synchronously joins cached-shader compilation workers. Preserve their
	// compiled driver libraries before gameplay can crash or iOS can terminate us.
	// This is a checkpoint of encountered shaders, not an offline compile of all
	// shaders a title may generate later. Respect the existing user cache opt-out.
	if (!Emu.IsStopped() && !g_cfg.video.disable_on_disk_shader_cache &&
		g_cfg.video.shadermode != shader_mode::interpreter_only)
	{
		m_device->checkpoint_pipeline_cache();
		rsx_log.notice("NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1: cached-shader warm-up finished; driver cache checkpoint attempted");
	}
#endif
}'''
    updated[render] = updated[render].replace(body, replacement)
    # Verify EVERY output before writing ANY file. This also catches unintended
    # replacement count changes or a modified local coherence template.
    for name, text in updated.items():
        if digest(text.encode('utf-8')) != targets[name]['after']:
            raise RuntimeError(f'Build 266 postimage mismatch: {name}')
    for name, text in updated.items():
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding='utf-8')
    print('Build 266 JIT/progress/shader checkpoint applied; all source hashes verified')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('--upstream-source', type=Path,
                        help='Offline test fixture, still required to match immutable upstream hashes')
    args = parser.parse_args()
    patch(args.source.resolve(), args.upstream_source.resolve() if args.upstream_source else None)
