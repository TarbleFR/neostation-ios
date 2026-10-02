"""Lock historical Core changes, then the explicitly reviewed guest-data relay delta."""
from pathlib import Path
import hashlib
import json
import re
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = '3ccde925351b3e59985ba466e013e87a857d6ad0'
RELAY_BASE = '35ce4bc20a36ed06155944a0228db42f452a0d9f'
candidate = runpy.run_path(str(ROOT / 'test/import_memory_candidate_scope_test.py'))


def original(path, revision=BASE):
    return subprocess.check_output(['git', 'show', revision + ':' + path], cwd=ROOT)


def sections(patch):
    chunks = re.split(rb'(?m)(?=^diff --git )', patch)
    assert not chunks[0], 'Unexpected content before canonical patch sections'
    result = {}
    for chunk in chunks[1:]:
        match = re.match(rb'diff --git a/(\S+) b/(\S+)\n', chunk)
        assert match and match[1] == match[2], 'Core rename or invalid section'
        path = match[1].decode('utf-8')
        assert path not in result, 'Duplicate canonical patch section: ' + path
        assert b'deleted file mode ' not in chunk and b'old mode ' not in chunk, path
        result[path] = chunk
    return result


def postimage_lines(section):
    # Equal braces may be represented as context or additions when Git
    # regenerates a unified hunk. Compare the represented final source.
    return b''.join(line[1:] for line in section.splitlines(keepends=True)
                    if line.startswith((b' ', b'+')) and not line.startswith(b'+++'))


def hunks(section):
    result = []
    for chunk in re.split(rb'(?m)(?=^@@ )', section)[1:]:
        header, body = chunk.split(b'\n', 1)
        match = re.match(rb'@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(?: .*)?$', header)
        assert match, 'Invalid canonical hunk'
        old_start, old_count, new_start, new_count = [
            int(value) if value is not None else 1 for value in match.groups()
        ]
        lines = body.splitlines(keepends=True)
        assert all(line.startswith((b' ', b'+', b'-')) for line in lines), 'Invalid hunk body'
        preimage = b''.join(line[1:] for line in lines if line.startswith((b' ', b'-')))
        postimage = b''.join(line[1:] for line in lines if line.startswith((b' ', b'+')))
        assert len(preimage.splitlines()) == old_count
        assert len(postimage.splitlines()) == new_count
        result.append((old_start, old_count, new_start, new_count, preimage, postimage))
    assert result, 'Missing canonical hunks'
    return result


def only_appended_getter(before, after, addition):
    old_hunks, new_hunks = hunks(before), hunks(after)
    assert len(old_hunks) == len(new_hunks), 'Unexpected runtime hunk'
    for index, (old_hunk, new_hunk) in enumerate(zip(old_hunks, new_hunks)):
        extra = addition if index == len(old_hunks) - 1 else b''
        assert new_hunk[:3] == old_hunk[:3], 'Runtime preimage range or hunk position changed'
        assert new_hunk[3] == old_hunk[3] + len(extra.splitlines())
        assert new_hunk[4] == old_hunk[4], 'Runtime preimage/deletions changed'
        assert new_hunk[5] == old_hunk[5] + extra, 'Runtime change beyond the optional getter'


LEGACY_AUDITED_CORE_FILES = {
    'rpcs3/Emu/Cell/SPUCommonRecompiler.cpp',
    'rpcs3/Emu/RSX/VK/VKGSRender.cpp',
    'rpcs3/Emu/RSX/VK/VKHelpers.cpp',
    'rpcs3/ios/NeoSwapClient.h',
    'rpcs3/ios/NeoSwapClientStats.h',
    'rpcs3/ios/RPCS3IOS.cpp',
    'rpcs3/ios/RPCS3IOS.h',
    'rpcs3/ios/RPCS3IOS.exports',
    'rpcs3/Emu/RSX/VK/vkutils/buffer_object.cpp',
    'rpcs3/Emu/RSX/VK/vkutils/memory.h',
    'rpcs3/ios/NeoSwapVulkanBuffer.h',
}
LEGACY_ADDED_CORE_FILES = {
    'rpcs3/Emu/RSX/VK/VKHelpers.cpp', 'rpcs3/ios/NeoSwapClientStats.h',
    'rpcs3/Emu/RSX/VK/vkutils/buffer_object.cpp', 'rpcs3/ios/NeoSwapVulkanBuffer.h',
}
old = json.loads(original('build-utils/rpcs3/canonical-source.json'))
# First prove that the already-reviewed Vulkan/Core delta is unchanged. The
# new guest-data permission is applied only in the second stage below.
new = json.loads(original('build-utils/rpcs3/canonical-source.json', RELAY_BASE))
assert set(new['files_sha256']) == set(old['files_sha256']) | LEGACY_ADDED_CORE_FILES
changed = {path for path, value in new['files_sha256'].items()
           if old['files_sha256'].get(path) != value}
assert changed == LEGACY_AUDITED_CORE_FILES, 'Unaudited Core postimages: ' + str(changed ^ LEGACY_AUDITED_CORE_FILES)
allowed_manifest_changes = {'files_sha256', 'patch_sha256', 'policy', 'xitrix_v0101_backports', 'neoswap_vulkan_buffers'}
assert set(new) == set(old) | {'xitrix_v0101_backports', 'neoswap_vulkan_buffers'}
for key in set(old) - allowed_manifest_changes:
    assert new[key] == old[key], 'Unrelated canonical contract changed: ' + key
assert new['device_runtime_tested'] is False
assert new['neoswap']['client_abi'] == 1
assert new['neoswap']['broker_compiled_into_host_only'] is True
backports = new['xitrix_v0101_backports']
assert backports['release'] == 'v0.10.1'
assert backports['source_head'] == '6747b75ac96d43674d58e822c527ec6b07519c5f'
assert backports['commits'] == [
    '8bd938e9de9ff6455f312cdf8bd64bd37a064c4e',
    '1d13d1e6bbabfbb7a873f2c608c52525ff470e25',
    '6747b75ac96d43674d58e822c527ec6b07519c5f',
]
assert backports['device_runtime_tested'] is False

patch = original('build-utils/rpcs3/embedded-core.patch', RELAY_BASE)
assert hashlib.sha256(patch).hexdigest() == new['patch_sha256']
before_sections = sections(original('build-utils/rpcs3/embedded-core.patch'))
after_sections = sections(patch)
assert set(after_sections) == set(before_sections) | LEGACY_ADDED_CORE_FILES
patch_changes = {path for path, value in after_sections.items()
                 if before_sections.get(path) != value}
assert patch_changes == LEGACY_AUDITED_CORE_FILES, 'Unaudited canonical patch section'
# Preserve every historical JIT, VM, GoW3, savestate, audio and decoder patch
# section outside the eleven previously audited production postimages.
for path, value in before_sections.items():
    if path not in LEGACY_AUDITED_CORE_FILES:
        assert after_sections[path] == value, 'Unrelated Core patch changed: ' + path

getter = (b'\nextern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_get_neoswap_client_stats'
          b'(NeoSwapClientStats* out) noexcept\n{\n'
          b'\treturn neostation::swap::snapshot(out);\n}\n')
cpp = 'rpcs3/ios/RPCS3IOS.cpp'
only_appended_getter(before_sections[cpp], after_sections[cpp], getter)
assert postimage_lines(after_sections[cpp]) == postimage_lines(before_sections[cpp]) + getter, \
    'Core runtime/JIT/VM/lifecycle changed beyond the optional diagnostic getter'
exports = 'rpcs3/ios/RPCS3IOS.exports'
only_appended_getter(before_sections[exports], after_sections[exports],
                     b'_rpcs3_ios_get_neoswap_client_stats\n')
assert postimage_lines(after_sections[exports]) == postimage_lines(before_sections[exports]) + \
    b'_rpcs3_ios_get_neoswap_client_stats\n', 'Existing Core exports changed'
header = 'rpcs3/ios/RPCS3IOS.h'
extra_header_lines = [
    b'+#include "NeoSwapClientStats.h"',
    b'+// Optional allocator diagnostics: caller supplies the exact struct size and',
    b'+// NEOSWAP_CLIENT_STATS_ABI. Independent of the main Core and allocator ABI.',
    b'+RPCS3_IOS_EXPORT int32_t rpcs3_ios_get_neoswap_client_stats(',
    b'+    NeoSwapClientStats* stats) RPCS3_IOS_NOEXCEPT;',
]


def header_edits(section):
    return [line for line in section.splitlines() if line.startswith((b'+', b'-'))
            and not line.startswith((b'+++', b'---'))]


header_changes = header_edits(after_sections[header])
for line in extra_header_lines:
    assert header_changes.count(line) == 1, 'Unexpected Core diagnostic declaration'
    header_changes.remove(line)
assert header_changes == header_edits(before_sections[header]), 'Main Core ABI fields changed'
assert candidate['manifest']['abi'] == {
    'rpcs3_runtime': 30, 'neoswap_allocator': 1, 'neoswap_client_stats': 1, 'neoswap_relay': 1, 'neoswap_storage': 1,
}
# CI also executes this check against the actual materialized production header.
native_test = (ROOT / 'test/rpcs3_xitrix_v0101_native_test.py').read_text()
assert "assert '#define RPCS3_IOS_ABI_VERSION 30u'" in native_test
assert 'test/rpcs3_xitrix_v0101_native_test.py' in (ROOT / 'build-utils/build_rpcs3_embedded_core.sh').read_text()

# The separately authorized guest-data relay has a narrow delta from the
# reviewed Build371 source. Historical Vulkan budgets/imports, JIT/PPU/SPU,
# renderer and lifecycle source must remain byte-identical at this boundary.
RELAY_CORE_FILES = {
    'rpcs3/Emu/Memory/vm.cpp',
    'rpcs3/Emu/Cell/lv2/sys_mmapper.cpp',
    'rpcs3/util/vm.hpp',
    'rpcs3/util/vm_native.cpp',
    'rpcs3/ios/NeoSwapRelay.h',
    'rpcs3/ios/NeoSwapRelayClient.h',
    'rpcs3/ios/RPCS3IOS.cpp',
    'rpcs3/ios/RPCS3IOS.h',
    'rpcs3/ios/RPCS3IOS.exports',
}
RELAY_ADDED_CORE_FILES = {
    'rpcs3/Emu/Cell/lv2/sys_mmapper.cpp',
    'rpcs3/util/vm.hpp',
    'rpcs3/util/vm_native.cpp',
    'rpcs3/ios/NeoSwapRelay.h',
    'rpcs3/ios/NeoSwapRelayClient.h',
}
AUDITED_CORE_FILES = LEGACY_AUDITED_CORE_FILES | RELAY_CORE_FILES
ADDED_CORE_FILES = LEGACY_ADDED_CORE_FILES | RELAY_ADDED_CORE_FILES
CPU_BASE = '7a900c93c80cf09a1ea01a9f85f72496025e88b2'
STORAGE_BASE = 'e960e163749994d14de863bb101ed19f897cd624'
active_manifest = json.loads(original('build-utils/rpcs3/canonical-source.json', STORAGE_BASE))
storage_manifest = json.loads((ROOT / 'build-utils/rpcs3/canonical-source.json').read_text())
current = json.loads(original('build-utils/rpcs3/canonical-source.json', CPU_BASE))
assert set(current) == set(new) | {'neoswap_guest_relay'}
for key in set(new) - {'files_sha256', 'patch_sha256', 'policy'}:
    assert current[key] == new[key], 'Unrelated canonical contract changed by relay: ' + key
assert set(current['files_sha256']) == set(new['files_sha256']) | RELAY_ADDED_CORE_FILES
relay_changed = {path for path, value in current['files_sha256'].items()
                 if new['files_sha256'].get(path) != value}
assert relay_changed == RELAY_CORE_FILES, 'Unaudited relay postimages: ' + str(relay_changed ^ RELAY_CORE_FILES)
# Candidate postimages are checked below after the new CPU-only delta.
relay_contract = current['neoswap_guest_relay']
assert relay_contract['client_abi'] == 1
assert relay_contract['broker_compiled_into_host_only'] is True
assert relay_contract['real_iphone_validated'] is False
assert 'guest data' in relay_contract['scope'] and 'alias' in relay_contract['scope']

current_patch = original('build-utils/rpcs3/embedded-core.patch', CPU_BASE)
assert hashlib.sha256(current_patch).hexdigest() == current['patch_sha256']
current_sections = sections(current_patch)
assert set(current_sections) == set(after_sections) | RELAY_ADDED_CORE_FILES
relay_patch_changes = {path for path, value in current_sections.items()
                       if after_sections.get(path) != value}
assert relay_patch_changes == RELAY_CORE_FILES, 'Unaudited relay canonical patch section'
for path, value in after_sections.items():
    if path not in RELAY_CORE_FILES:
        assert current_sections[path] == value, 'Relay changed unrelated historical Core source: ' + path


def hunk_signature(hunk):
    # New line offsets legitimately shift after an earlier relay insertion.
    # Original positions, context, deletions and final text remain exact.
    return hunk[0], hunk[1], hunk[4], hunk[5]


def hunk_digest(hunk):
    start, count, preimage, postimage = hunk_signature(hunk)
    return hashlib.sha256(str(start).encode() + b':' + str(count).encode() +
                          b'\0' + preimage + b'\0' + postimage).hexdigest()


# These are the exact reviewed new hunks, not values derived from the mutable
# manifest. Changing any other function in these broad VM files fails closed.
# vm.hpp: explicit guest-data tag, optional member and constructor parameter.
# vm_native.cpp: two constructors, retryable destructor retirement,
# map/try_map, map_self failure and unmap paths.
# vm.cpp: five guest-data constructor calls and two sudo-alias unmap guards.
# sys_mmapper.cpp: only two shareable guest-data constructor calls.
REVIEWED_RELAY_HUNKS = {
    'rpcs3/util/vm.hpp': [
        '9ac70e11a88e69b18443c76416dfd951daf43afead15ef06ea4145b41ba60d86',
        'ad560adb38d39ab6348cf5ea9058a8b8e882c7aaf9bf155e1d46510851ec1d1c',
        '7ec7511848bdfcf24aa33ee0c85fd37980ecc0fe881e41a9dd9fdaf75832811b',
    ],
    'rpcs3/util/vm_native.cpp': [
        '06d0bdd057c822c9dc2ee658c471c748eb26c3b357f5aae3764d4a97c0917a5d',
        '8fe0989f3ee3479fd07ffabbed92442f8a2fcf2e451cfa7fe07a700f3f1cdac9',
        '1478827a2abfd66fba134208a18c0780f0fe2bc617a7ed78d41844a0af4591a0',
        '45b66f83468e97cbb7b21ed5aacefc9b34668473ec4f94a1e8511494a0511f74',
        '6fe0c395faba1172f1cdaa50ba5e211821fb07a4d340c2011372930a7858a002',
        'cf9c62357b2aa04dbaf6bde3eed33c765ff8a9768fcfee09a47a73e0da96ae8b',
        '825a7232085f546760e27f00a44a6d7e96479e5398b494e6d4b63c580e9d9fea',
        'e4cfd39b2b674694cac8176004f6797d301fd9e2a66deb6da347bac8456bc998',
        '32736fe43ff196b437af3514a2581e90c63ef27a173a0ef33bd7cbce4275bc7d',
        '4b081a49e72527ce9986bf740c8ee6f1cd8195090c4931ca96ea0145ae8092e6',
    ],
    'rpcs3/Emu/Memory/vm.cpp': [
        'd84e0ca31dcaa285784be71b42a1a6530cfc7f50b4a2c20812a2bc3c6fa12e41',
        '7e5e3118fa5bd9067cc200c2f5e93db465f6316ab18c7f367980d28d4b1ede5a',
        'e64b55e26e26287f47fad4fd9694513cfcd98cc415135fa0f4953e1089eeb4a0',
        'aef4b9cb80ce357dcfce750c4503fb4d83a0afc50f2aca44eef5ee1a5acb3efa',
        'e5b6b848dd9dca71952894cec18043828661d56568e6e67203983449f37a6856',
        '13bd8dcfff6e6706144932e1b276bfa3c7e2a7b7e83ec647b9252ad500e9685b',
        'ec47f11891e2d626f652dafd37aa084e96c980f96e8a927f217f43d90cc6b3b8',
    ],
    'rpcs3/Emu/Cell/lv2/sys_mmapper.cpp': [
        '9f3c1a4e3a236b84defe4f66e06cfddfe149946a548cb317e0741e30e80a85a0',
        'b9cfb1eeed78cf04ca886d0ee247c1316b79bced62597c58b3f287e6301ce790',
    ],
}
for path, reviewed in REVIEWED_RELAY_HUNKS.items():
    historical = [hunk_signature(hunk) for hunk in hunks(after_sections[path])] if path in after_sections else []
    additions = []
    for hunk in hunks(current_sections[path]):
        signature = hunk_signature(hunk)
        if signature in historical:
            historical.remove(signature)
        else:
            additions.append(hunk_digest(hunk))
    assert not historical, 'Historical VM/locking/savestate hunk changed or removed: ' + path
    assert additions == reviewed, 'Unreviewed guest-data VM change: ' + path

relay_setter = (b'\n// Optional guest-data relay binding. Main Core ABI and NeoSwap v1 are unchanged.\n'
                b'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_neoswap_relay_api(const NeoSwapRelayAPI* api) noexcept\n'
                b'{\n\treturn neostation::relay::install(api);\n}\n')
old_runtime, relay_runtime = hunks(after_sections[cpp]), hunks(current_sections[cpp])
assert len(old_runtime) == len(relay_runtime), 'Unexpected guest relay runtime hunk'
offset = 0
for index, (old_hunk, relay_hunk) in enumerate(zip(old_runtime, relay_runtime)):
    expected = old_hunk[5]
    if index == 0:
        include = b'#include "NeoSwapClient.h"\n'
        assert expected.count(include) == 1
        expected = expected.replace(include, include + b'#include "NeoSwapRelayClient.h"\n')
    if index == len(old_runtime) - 1:
        expected += relay_setter
    assert relay_hunk[:2] == old_hunk[:2] and relay_hunk[4] == old_hunk[4], 'Relay changed runtime preimage/deletions'
    assert relay_hunk[2] == old_hunk[2] + offset, 'Relay moved an unrelated runtime hunk'
    assert relay_hunk[5] == expected, 'Runtime changed beyond relay include and setter'
    offset += len(expected.splitlines()) - old_hunk[3]

only_appended_getter(after_sections[exports], current_sections[exports],
                     b'\n_rpcs3_ios_set_neoswap_relay_api\n')
relay_header_lines = [
    b'+#include "NeoSwapRelay.h"',
    b'+// Optional guest-data relay, bound by the host before initialize/boot.',
    b'+RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_neoswap_relay_api(',
    b'+    const NeoSwapRelayAPI* api) RPCS3_IOS_NOEXCEPT;',
]
relay_header_changes = header_edits(current_sections[header])
for line in relay_header_lines:
    assert relay_header_changes.count(line) == 1, 'Unexpected guest relay Core declaration'
    relay_header_changes.remove(line)
assert relay_header_changes == header_edits(after_sections[header]), 'Relay changed existing runtime ABI declarations'
old_header, relay_header = hunks(after_sections[header]), hunks(current_sections[header])
assert len(old_header) == len(relay_header), 'Unexpected guest relay ABI hunk'
offset = 0
for old_hunk, relay_hunk in zip(old_header, relay_header):
    expected = old_hunk[5].replace(b'#include "NeoSwapClientStats.h"\n',
                                  b'#include "NeoSwapClientStats.h"\n#include "NeoSwapRelay.h"\n')
    declaration = b'// Optional allocator diagnostics: caller supplies the exact struct size and\n'
    expected = expected.replace(declaration, b'\n'.join(line[1:] for line in relay_header_lines[1:]) + b'\n' + declaration)
    assert relay_hunk[:2] == old_hunk[:2] and relay_hunk[4] == old_hunk[4], 'Relay changed runtime ABI preimage'
    assert relay_hunk[2] == old_hunk[2] + offset, 'Relay moved an unrelated ABI hunk'
    assert relay_hunk[5] == expected, 'Relay changed existing runtime ABI source'
    offset += len(expected.splitlines()) - old_hunk[3]


# Build395 authorizes no JIT/PPU/SPU/VM/graphics-policy change. It adds a
# donor-only sub-MiB request helper and changes one RSX CPU call site.
CPU_CORE_FILES = {'rpcs3/ios/NeoSwapClient.h', 'rpcs3/Emu/RSX/Common/aligned_malloc.hpp'}
active_patch = original('build-utils/rpcs3/embedded-core.patch', STORAGE_BASE)
assert hashlib.sha256(active_patch).hexdigest() == active_manifest['patch_sha256']
active_sections = sections(active_patch)
assert set(active_sections) == set(current_sections)
assert {p for p in active_sections if active_sections[p] != current_sections[p]} == CPU_CORE_FILES
for p in set(current_sections) - CPU_CORE_FILES:
    assert active_sections[p] == current_sections[p], 'Unrelated Core section changed by CPU experiment: ' + p
assert set(active_manifest) == set(current) | {'neoswap_cpu_buffers'}
for key in set(current) - {'files_sha256', 'patch_sha256', 'policy'}:
    assert active_manifest[key] == current[key], 'Existing Core policy changed: ' + key
assert set(active_manifest['files_sha256']) == set(current['files_sha256'])
assert {p for p in active_manifest['files_sha256'] if active_manifest['files_sha256'][p] != current['files_sha256'][p]} == CPU_CORE_FILES
aligned = 'rpcs3/Emu/RSX/Common/aligned_malloc.hpp'
expected = current_sections[aligned].replace(
    b'neostation::swap::try_allocate(NEOSWAP_RPCS3, size, Align)',
    b'neostation::swap::try_allocate_cpu(NEOSWAP_RPCS3, size, Align)')
assert active_sections[aligned] == expected, 'CPU allocator changed beyond the opt-in call'
client = postimage_lines(active_sections['rpcs3/ios/NeoSwapClient.h'])
start = client.index(b'// RSX CPU data only.')
end = client.index(b'inline int snapshot(')
assert hashlib.sha256(client[start:end]).hexdigest() == '5763595637829460a470729cf2c4c51d86d44d4fccb44a8f8bee4bf6bbb72d72'
assert client[:start] + client[end:] == postimage_lines(current_sections['rpcs3/ios/NeoSwapClient.h'])
AUDITED_CORE_FILES |= CPU_CORE_FILES
# Build396 preserves the entire historical audit above, adding seven reviewed postimages.
STORAGE_FILES = {
    'rpcs3/Emu/RSX/VK/VKProgramPipeline.cpp', 'rpcs3/Emu/RSX/VK/VKProgramPipeline.h',
    'rpcs3/ios/RPCS3IOS.cpp', 'rpcs3/ios/RPCS3IOS.exports',
    'rpcs3/ios/NeoSwapStorage/Client.h', 'rpcs3/ios/NeoSwapStorage/ShaderKey.h',
    'rpcs3/ios/NeoSwapStorage/StorageABI.h',
}
STORAGE_ADDED = STORAGE_FILES - {'rpcs3/ios/RPCS3IOS.cpp','rpcs3/ios/RPCS3IOS.exports'}
assert set(storage_manifest)==set(active_manifest)|{'neoswap_shader_storage'}
for key in set(active_manifest)-{'files_sha256','patch_sha256','policy'}:
    assert storage_manifest[key]==active_manifest[key], 'Historical policy changed by storage: '+key
assert set(storage_manifest['files_sha256'])==set(active_manifest['files_sha256'])|STORAGE_ADDED
assert {p for p,h in storage_manifest['files_sha256'].items() if active_manifest['files_sha256'].get(p)!=h}==STORAGE_FILES
storage_patch=(ROOT/'build-utils/rpcs3/embedded-core.patch').read_bytes()
assert hashlib.sha256(storage_patch).hexdigest()==storage_manifest['patch_sha256']
storage_sections=sections(storage_patch)
assert set(storage_sections)==set(active_sections)|STORAGE_ADDED
for path in set(active_sections)-STORAGE_FILES:
    assert hunks(storage_sections[path])==hunks(active_sections[path]), 'Unrelated source hunk changed by storage: '+path
runtime=postimage_lines(storage_sections[cpp])
expected_runtime=postimage_lines(active_sections[cpp])
include=b'#include "NeoSwapStorage/Client.h"\n'
assert runtime.count(include)==1
runtime=runtime.replace(include,b'')
setter=(b'\n// Optional host-owned regenerable bytecode cache; installing it does no I/O.\n'
        b'extern "C" RPCS3_IOS_EXPORT int32_t rpcs3_ios_set_storage_cache_api(const NeoSwapStorageAPI* api) noexcept\n'
        b'{\n    return neostation::storage_client::install(api);\n}\n')
assert runtime.endswith(setter), 'Storage setter implementation changed'
assert runtime[:-len(setter)].rstrip()==expected_runtime.rstrip(), 'Storage changed Core lifecycle/JIT'
assert postimage_lines(storage_sections[exports]).rstrip()==postimage_lines(active_sections[exports]).rstrip()+b'\n_rpcs3_ios_set_storage_cache_api'
for name in ('Client.h','ShaderKey.h','StorageABI.h'):
    assert hashlib.sha256((ROOT/'native/neoswap-storage'/name).read_bytes()).hexdigest()==storage_manifest['files_sha256']['rpcs3/ios/NeoSwapStorage/'+name]
assert storage_manifest['neoswap_shader_storage']['abi']==1
assert storage_manifest['neoswap_shader_storage']['host_owned'] is True
assert storage_manifest['neoswap_shader_storage']['device_runtime_tested'] is False
AUDITED_CORE_FILES |= STORAGE_FILES
current = storage_manifest
assert candidate['manifest']['rpcs3_postimages_sha256'] == {
    path: current['files_sha256'][path] for path in sorted(AUDITED_CORE_FILES)
}, 'Candidate/Core postimage identity drift'
assert current['neoswap_cpu_buffers']['minimum_bytes'] == 65536
assert current['neoswap_cpu_buffers']['maximum_exclusive_bytes'] == 1048576
assert current['neoswap_cpu_buffers']['generic_vulkan_threshold_unchanged'] is True
assert current['neoswap_cpu_buffers']['device_runtime_tested'] is False

abi_path = 'packages/neo_swap/ios/Classes/NeoSwap.h'
assert (ROOT / abi_path).read_bytes() == original(abi_path), 'Allocator v1 ABI changed'
for source, target in [
    (abi_path, 'rpcs3/ios/NeoSwap.h'),
    ('native/neoswap/NeoSwapClient.h', 'rpcs3/ios/NeoSwapClient.h'),
    ('packages/neo_swap/ios/Classes/NeoSwapClientStats.h', 'rpcs3/ios/NeoSwapClientStats.h'),
    ('packages/neo_swap/ios/Classes/NeoSwapRelay.h', 'rpcs3/ios/NeoSwapRelay.h'),
]:
    value = (ROOT / source).read_bytes().replace(b'\r\n', b'\n')
    assert hashlib.sha256(value).hexdigest() == current['files_sha256'][target], 'ABI/client drift: ' + source

host = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
assert host.index('rpcs3_ios_set_neoswap_api') < host.index('self->_api.initialize(&options)')
assert 'NeoSwap_RegisterClient(NEOSWAP_RPCS3)' in host
assert 'NeoSwapRelay_WaitReady(10000)' in host
assert 'relayReady != NEOSWAP_RELAY_OK' in host and 'RPCS3_NEOSWAP_NOT_READY' in host
assert host.index('NeoSwapRelay_WaitReady(10000)') < host.index('NeoSwap_RegisterClient(NEOSWAP_RPCS3)')
assert 'dlsym(handle, "rpcs3_ios_get_neoswap_client_stats")' in host
broker = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwap.cpp').read_text()
assert broker.count('struct Broker {') == 1
assert broker.count('Broker& broker() { static Broker b; return b; }') == 1
catalog = json.loads((ROOT / 'native/neoswap/localizations.json').read_text())
assert set(catalog) == {'en', 'es', 'ru', 'zh', 'zh_Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
print('PASS NeoSwap scope: historical Vulkan/Core changes retained; seventeen reviewed postimages; '
      'optional shader CPU cache; JIT/PPU/SPU and allocator v1 unchanged; '
      'runtime ABI30/relay ABI1; one host broker; no physical iPhone validation claim')
