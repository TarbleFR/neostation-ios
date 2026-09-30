"""Lock the audited RPCS3 delta and unchanged allocator/JIT/VM contracts."""
from pathlib import Path
import hashlib
import json
import re
import runpy
import subprocess

ROOT = Path(__file__).resolve().parents[1]
BASE = '3ccde925351b3e59985ba466e013e87a857d6ad0'
candidate = runpy.run_path(str(ROOT / 'test/import_memory_candidate_scope_test.py'))


def original(path):
    return subprocess.check_output(['git', 'show', BASE + ':' + path], cwd=ROOT)


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


AUDITED_CORE_FILES = {
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
ADDED_CORE_FILES = {
    'rpcs3/Emu/RSX/VK/VKHelpers.cpp', 'rpcs3/ios/NeoSwapClientStats.h',
    'rpcs3/Emu/RSX/VK/vkutils/buffer_object.cpp', 'rpcs3/ios/NeoSwapVulkanBuffer.h',
}
old = json.loads(original('build-utils/rpcs3/canonical-source.json'))
new = json.loads((ROOT / 'build-utils/rpcs3/canonical-source.json').read_text())
assert set(new['files_sha256']) == set(old['files_sha256']) | ADDED_CORE_FILES
changed = {path for path, value in new['files_sha256'].items()
           if old['files_sha256'].get(path) != value}
assert changed == AUDITED_CORE_FILES, 'Unaudited Core postimages: ' + str(changed ^ AUDITED_CORE_FILES)
assert candidate['manifest']['rpcs3_postimages_sha256'] == {
    path: new['files_sha256'][path] for path in sorted(AUDITED_CORE_FILES)
}, 'Candidate/Core postimage identity drift'
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

patch = (ROOT / 'build-utils/rpcs3/embedded-core.patch').read_bytes()
assert hashlib.sha256(patch).hexdigest() == new['patch_sha256']
before_sections = sections(original('build-utils/rpcs3/embedded-core.patch'))
after_sections = sections(patch)
assert set(after_sections) == set(before_sections) | ADDED_CORE_FILES
patch_changes = {path for path, value in after_sections.items()
                 if before_sections.get(path) != value}
assert patch_changes == AUDITED_CORE_FILES, 'Unaudited canonical patch section'
# Preserve every historical JIT, VM, GoW3, savestate, audio and decoder patch
# section outside the eight explicitly audited production postimages.
for path, value in before_sections.items():
    if path not in AUDITED_CORE_FILES:
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
    'rpcs3_runtime': 30, 'neoswap_allocator': 1, 'neoswap_client_stats': 1,
}
# CI also executes this check against the actual materialized production header.
native_test = (ROOT / 'test/rpcs3_xitrix_v0101_native_test.py').read_text()
assert "assert '#define RPCS3_IOS_ABI_VERSION 30u'" in native_test
assert 'test/rpcs3_xitrix_v0101_native_test.py' in (ROOT / 'build-utils/build_rpcs3_embedded_core.sh').read_text()

abi_path = 'packages/neo_swap/ios/Classes/NeoSwap.h'
assert (ROOT / abi_path).read_bytes() == original(abi_path), 'Allocator v1 ABI changed'
for source, target in [
    (abi_path, 'rpcs3/ios/NeoSwap.h'),
    ('native/neoswap/NeoSwapClient.h', 'rpcs3/ios/NeoSwapClient.h'),
    ('packages/neo_swap/ios/Classes/NeoSwapClientStats.h', 'rpcs3/ios/NeoSwapClientStats.h'),
]:
    value = (ROOT / source).read_bytes().replace(b'\r\n', b'\n')
    assert hashlib.sha256(value).hexdigest() == new['files_sha256'][target], 'ABI/client drift: ' + source

host = (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
assert host.index('rpcs3_ios_set_neoswap_api') < host.index('self->_api.initialize(&options)')
assert 'NeoSwap_RegisterClient(NEOSWAP_RPCS3)' in host
assert 'dlsym(handle, "rpcs3_ios_get_neoswap_client_stats")' in host
broker = (ROOT / 'packages/neo_swap/ios/Classes/NeoSwap.cpp').read_text()
assert broker.count('struct Broker {') == 1
assert broker.count('Broker& broker() { static Broker b; return b; }') == 1
catalog = json.loads((ROOT / 'native/neoswap/localizations.json').read_text())
assert set(catalog) == {'en', 'es', 'ru', 'zh', 'zh_Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
print('PASS NeoSwap scope: eleven audited RPCS3 postimages including coherent Vulkan buffer imports; runtime ABI30/allocator ABI1; '
      'historical JIT/VM/GoW3/savestate patch sections retained; one host broker; no device validation claim')
