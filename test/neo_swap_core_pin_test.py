#!/usr/bin/env python3
"""Pin RPCS3 source, recipe and native regressions independently of the host broker.

The normal mode requires the published Core commit to contain these exact
inputs. --source-only is an intermediate source check, never an artifact pin
validation; --source-root additionally verifies every materialized postimage.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = '22f1152783cef1f7e04af7b1c895173e28fd5b03'
PATCH_SHA256 = '82690d3d19c0ce7a631709f9e798603f94a65505724198d7674f26f162c8efe4'
BACKPORTS = (
    '8bd938e9de9ff6455f312cdf8bd64bd37a064c4e',
    '1d13d1e6bbabfbb7a873f2c608c52525ff470e25',
    '6747b75ac96d43674d58e822c527ec6b07519c5f',
)
V011_BACKPORTS = (
    '3dc496307b86f81a409f03816af07261a49748d3',
    '7137b41aed01d94345e35719a98fdc4190d08e50',
    '3ebf5c99fada6cd15da346ab216c96ba09a81f63',
    '57ce3bf6a9f6a522fcb7b8f2ae140b59b19f0cd3',
    '395636f5a64ec33fc3b9b44c8f01f1c5d69b9217',
)

# Core source, recipe, ABI and native acceptance evidence. NeoSwap.cpp,
# NeoSwapHost.h, donation helpers and broker-only tests belong to the host.
CORE_INPUTS = (
    'native/neoswap-storage/StorageABI.h',
    'native/neoswap-storage/Client.h',
    'native/neoswap-storage/ShaderKey.h',
    'test/rpcs3_shader_storage_test.py',
    'test/native/rpcs3_shader_storage_client_test.cpp',
    'native/neoswap-storage/SourceABI.h',
    'native/neoswap-storage/SourceClient.h',
    'native/neoswap-storage/SourceClient.cpp',
    'native/neoswap-storage/FrameClient.h',
    'native/neoswap-storage/VideoBuffer.h',
    'test/rpcs3_video_frame_archive_test.py',
    'test/native/rpcs3_video_frame_archive_test.cpp',
    'build-utils/run_vdec_archive_validation.sh',
    'test/rpcs3_source_archive_test.py',
    'test/native/rpcs3_source_archive_client_test.cpp',
    'build-utils/build_rpcs3_embedded_core.sh',
    'build-utils/materialize_rpcs3_core.py',
    'build-utils/apply_rpcs3_llvm_patch.py',
    'build-utils/rpcs3/canonical-source.json',
    'build-utils/rpcs3/embedded-core.patch',
    'build-utils/rpcs3/llvm-aarch64-ghc-emergency-spill.patch',
    'build-utils/rpcs3_core_syntax_gate.py',
    'build-utils/validate_rpcs3_embedded_core.py',
    'build-utils/validate_rpcs3_passive_dlopen.py',
    'build-utils/patch_rpcs3_build301_passive_dlopen.py',  # validate() imported, never applied.
    'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h',
    'packages/neo_swap/ios/Classes/NeoSwap.h',
    'packages/neo_swap/ios/Classes/NeoSwapClientStats.h',
    'packages/neo_swap/ios/Classes/NeoSwapRelay.h',
    'native/neoswap/NeoSwapClient.h',
    'test/neo_swap_core_pin_test.py',
    'test/neoswap_rpcs3_allocator_test.cpp',
    'test/neoswap_cpu_buffers_test.cpp',
    'test/rpcs3_neoswap_vulkan_buffer_test.py',
    'test/native/rpcs3_neoswap_vulkan_buffer_test.cpp',
    'test/rpcs3_neoswap_relay_test.py',
    'test/native/rpcs3_neoswap_relay_test.cpp',
    'test/rpcs3_core_syntax_gate_test.py',
    'test/rpcs3_embedded_core_validator_test.py',
    'test/rpcs3_preprocessor_balance_test.py',
    'test/rpcs3_build301_passive_dlopen_test.py',
    'test/rpcs3_atomic_startup_test.py',
    'test/rpcs3_failed_startup_test.py',
    'test/rpcs3_build264_gow3_core_test.py',
    'test/rpcs3_build351_gow3_engine_test.py',
    'test/rpcs3_build352_gow3_memory_test.py',
    'test/rpcs3_build353_xitrix_v010_test.py',
    'test/rpcs3_armsx3_performance_patch_test.py',
    'test/rpcs3_build435_core_delta_test.py',
    'test/native/rpcs3_build435_core_delta_test.cpp',
    'test/rpcs3_ios_ppu_compile_budget_test.cpp',
    'test/rpcs3_ppu_no_size_split_policy_test.cpp',
    'test/rpcs3_xitrix_v0101_native_test.py',
    'test/rpcs3_xitrix_v011_native_test.py',
    'test/native/rpcs3_spu_analyzer_support.h',
    'test/native/rpcs3_spu_branch_analyzer_test.cpp',
    'test/rpcs3_spu_warmup_test.py',
    'test/native/rpcs3_spu_warmup_test.cpp',
    'test/native/rpcs3_vk_memory_pressure_test.cpp',
    'test/native/rpcs3_vk_conditional_render_test.cpp',
    'test/native/rpcs3_neoswap_stats_getter_test.cpp',
    '.github/workflows/rpcs3-core.yml',
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def core_input_hashes(root: Path = ROOT) -> dict[str, str]:
    result = {}
    for relative in CORE_INPUTS:
        path = root / relative
        require(path.is_file() and not path.is_symlink(), f'Missing regular Core input: {relative}')
        result[relative] = hashlib.sha256(path.read_bytes()).hexdigest()
    return result


def validate_core_scheduling(workflow: str) -> None:
    require(re.search(r'^concurrency:', workflow, re.M) is None,
            'Workflow-level concurrency can cancel a pinned Core even when the build job is skipped')
    require('    concurrency:\n      group: neostation-rpcs3-core-${{ github.sha }}\n      cancel-in-progress: false\n' in workflow,
            'Core job must preserve running builds and isolate immutable source SHAs')
    require("    if: ${{ !contains(github.event.head_commit.message, '[rpcs3-host-integration]') }}" in workflow,
            'Host-only integration must not rebuild the referenced Core')


def validate_source_contract(root: Path = ROOT, source_root: Path | None = None) -> None:
    core_input_hashes(root)
    manifest = json.loads((root / 'build-utils/rpcs3/canonical-source.json').read_text())
    patch = (root / 'build-utils/rpcs3/embedded-core.patch').read_bytes()
    require(manifest['upstream_repository'] == 'XITRIX/rpcs3', 'Unexpected source repository')
    require(manifest['upstream_commit'] == UPSTREAM, 'Unexpected source base')
    require(hashlib.sha256(patch).hexdigest() == manifest['patch_sha256'] == PATCH_SHA256,
            'The reviewed canonical Core delta changed')
    require(tuple(manifest['xitrix_v0101_backports']['commits']) == BACKPORTS,
            'Unexpected v0.10.1 backport scope')
    require(tuple(manifest['xitrix_v011_backports']['commits']) == V011_BACKPORTS and
            manifest['xitrix_v011_backports']['device_runtime_tested'] is False,
            'Unexpected XITRIX v0.11 import scope')
    require(manifest['device_runtime_tested'] is False and
            manifest['xitrix_v0101_backports']['device_runtime_tested'] is False,
            'Source tests cannot establish physical-device validation')
    require(manifest['neoswap']['client_abi'] == 1 and
            manifest['neoswap']['broker_compiled_into_host_only'] is True,
            'Core must borrow ABI 1; host owns the broker')
    require(manifest['neoswap_guest_relay']['client_abi'] == 1 and
            manifest['neoswap_guest_relay']['broker_compiled_into_host_only'] is True and
            manifest['neoswap_guest_relay']['real_iphone_validated'] is False,
            'Core must borrow relay ABI 1 from the host without claiming device proof')
    for host, core in (
        ('packages/neo_swap/ios/Classes/NeoSwap.h', 'rpcs3/ios/NeoSwap.h'),
        ('packages/neo_swap/ios/Classes/NeoSwapClientStats.h', 'rpcs3/ios/NeoSwapClientStats.h'),
        ('packages/neo_swap/ios/Classes/NeoSwapRelay.h', 'rpcs3/ios/NeoSwapRelay.h'),
        ('native/neoswap/NeoSwapClient.h', 'rpcs3/ios/NeoSwapClient.h'),
    ):
        payload = (root / host).read_bytes().replace(b'\r\n', b'\n')
        require(hashlib.sha256(payload).hexdigest() == manifest['files_sha256'][core],
                f'Host/Core client contract differs: {host}')
    require('NEOSWAP_ABI = 1' in (root / 'packages/neo_swap/ios/Classes/NeoSwap.h').read_text(),
            'Unexpected allocator ABI')
    require('NEOSWAP_CLIENT_STATS_ABI = 1' in (root / 'packages/neo_swap/ios/Classes/NeoSwapClientStats.h').read_text(),
            'Unexpected diagnostics ABI')
    require('NEOSWAP_RELAY_ABI = 1' in (root / 'packages/neo_swap/ios/Classes/NeoSwapRelay.h').read_text(),
            'Unexpected page-relay ABI')
    for name in ('StorageABI.h', 'Client.h', 'ShaderKey.h', 'SourceABI.h', 'SourceClient.h', 'SourceClient.cpp', 'FrameClient.h', 'VideoBuffer.h'):
        payload = (root/'native/neoswap-storage'/name).read_bytes()
        require(hashlib.sha256(payload).hexdigest() == manifest['files_sha256']['rpcs3/ios/NeoSwapStorage/'+name], 'Storage Core contract differs: '+name)
    recipe = (root / 'build-utils/build_rpcs3_embedded_core.sh').read_text()
    require(manifest['neoswap_source_archive']['abi'] == 1 and
            manifest['neoswap_source_archive']['host_owned'] is True and
            manifest['neoswap_source_archive']['device_tested'] is False,
            'Cold GLSL source archive must be host-owned, independently versioned and honestly unvalidated on device')
    require('test/rpcs3_source_archive_test.py' in recipe, 'Missing production cold-source regression')
    require(manifest['neoswap_video_frames']['domain']==3 and manifest['neoswap_video_frames']['device_tested'] is False,
            'Owned video domain must remain independently scoped and honestly unvalidated on device')
    require('test/rpcs3_video_frame_archive_test.py' in (root/'.github/workflows/rpcs3-core.yml').read_text(),
            'Missing real decoded-frame and mapping-release regression')
    require('RPCS3_IOS_ABI="${RPCS3_IOS_ABI:-30}"' in recipe, 'Unexpected main Core ABI')
    require('test/rpcs3_xitrix_v0101_native_test.py' in recipe, 'Missing production native regressions')
    require('test/rpcs3_neoswap_relay_test.py' in recipe, 'Missing actual shared-memory relay regressions')
    core_workflow = (root / '.github/workflows/rpcs3-core.yml').read_text()
    validate_core_scheduling(core_workflow)
    require('_rpcs3_ios_get_neoswap_client_stats' in core_workflow, 'Getter export must be verified')
    require('_rpcs3_ios_set_neoswap_relay_api' in core_workflow, 'Relay setter export must be verified')
    require("'neoswap_relay_abi':1" in core_workflow, 'Missing relay identity ABI')
    require("'neoswap_client_stats_abi':1" in core_workflow, 'Missing diagnostics identity ABI')
    require("'neoswap_source_archive_abi':1" in core_workflow and
            '_rpcs3_ios_set_source_archive_api' in core_workflow, 'Missing cold-source ABI/export identity')
    require("'core_input_sha256':core_input_hashes()" in core_workflow, 'Missing recipe/input identity')
    ipa_workflow = (root / '.github/workflows/neoswap-ipa.yml').read_text()
    block = ipa_workflow.split('# RPCS3_CORE_INPUTS_BEGIN\n', 1)[1].split('# RPCS3_CORE_INPUTS_END', 1)[0]
    inputs = re.findall(r'(?:build-utils|test|packages|native|\.github)/[^\s\\]+', block)
    require(len(inputs) == len(CORE_INPUTS) and set(inputs) == set(CORE_INPUTS),
            'IPA exact-diff inputs differ from the published Core input identity')
    require("assert identity['neoswap_client_stats_abi'] == 1" in ipa_workflow,
            'IPA must reject an old Core without diagnostics ABI 1')
    require("assert identity['neoswap_relay_abi'] == 1" in ipa_workflow,
            'IPA must reject a Core without shared-memory relay ABI 1')
    require('validate_core_input_identity(identity)' in ipa_workflow,
            'IPA must verify the complete Core input identity')
    require("assert identity['neoswap_source_archive_abi'] == 1" in ipa_workflow,
            'IPA must reject a Core without cold-source archive ABI 1')
    if source_root is not None:
        head = subprocess.check_output(['git', '-C', str(source_root), 'rev-parse', 'HEAD'], text=True).strip()
        require(head == UPSTREAM, 'Materialized source base changed')
        for relative, expected in manifest['files_sha256'].items():
            actual = hashlib.sha256((source_root / relative).read_bytes().replace(b'\r\n', b'\n')).hexdigest()
            require(actual == expected, f'Materialized postimage changed: {relative}')
        require('#define RPCS3_IOS_ABI_VERSION 30u' in (source_root / 'rpcs3/ios/RPCS3IOS.h').read_text(),
                'Materialized main ABI changed')
        require('_rpcs3_ios_get_neoswap_client_stats' in
                (source_root / 'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines(),
                'Materialized getter is not exported')
        require('_rpcs3_ios_set_neoswap_relay_api' in
                (source_root / 'rpcs3/ios/RPCS3IOS.exports').read_text().splitlines(),
                'Materialized relay setter is not exported')


def validate_exact_pin(commit: str, root: Path = ROOT) -> None:
    require(re.fullmatch(r'[0-9a-f]{40}', commit) is not None, 'Core pin must be a full commit SHA')
    actual = core_input_hashes(root)
    for relative in CORE_INPUTS:
        pinned = subprocess.run(['git', 'show', commit + ':' + relative], cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        require(pinned.returncode == 0, f'Core pin {commit} lacks input {relative}; rebuild and repin')
        require(hashlib.sha256(pinned.stdout).hexdigest() == actual[relative],
                f'Core input differs from pinned {commit}: {relative}; rebuild and repin')
        tree = subprocess.check_output(['git', 'ls-tree', commit, '--', relative], cwd=root, text=True)
        require(tree.split()[0] in ('100644', '100755'), f'Invalid pinned file mode: {relative}')
        require((tree.split()[0] == '100755') == bool((root / relative).stat().st_mode & 0o111),
                f'Core input mode differs from pin: {relative}')


def validate_core_input_identity(identity: dict, root: Path = ROOT) -> None:
    for name, expected in (
        ('abi_version', 30), ('neoswap_client_abi', 1), ('neoswap_client_stats_abi', 1), ('neoswap_relay_abi', 1),
        ('neoswap_storage_abi', 1), ('neoswap_source_archive_abi', 1),
        ('source_commit', UPSTREAM), ('source_patch_sha256', PATCH_SHA256),
    ):
        value = identity.get(name)
        require(type(value) is type(expected) and value == expected,
                f'Wrong Core identity {name}: {value!r}')
    require(identity.get('core_input_sha256') == core_input_hashes(root),
            'Published Core recipe, client contract or native tests differ from this candidate')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source-only', action='store_true', help='intermediate check; does not validate a binary pin')
    parser.add_argument('--source-root', type=Path, help='optional hash-verified materialized Core')
    parser.add_argument('--pin', help='override the workflow Core host SHA for a pin test')
    parser.add_argument('--identity', type=Path, help='optional downloaded Core identity.json')
    args = parser.parse_args()
    validate_source_contract(source_root=args.source_root)
    if args.source_only:
        require(not args.pin and not args.identity, '--source-only cannot validate a published Core pin/identity')
        print('PASS: reviewed Core source/recipe, ABI 30, client ABI 1, stats ABI 1, relay ABI 1; binary pin not checked')
        return
    workflow = (ROOT / '.github/workflows/neoswap-ipa.yml').read_text()
    pin = args.pin or os.environ.get('RPCS3_CORE_HOST_SHA')
    if not pin:
        pin = re.search(r'^\s+RPCS3_CORE_HOST_SHA: ([0-9a-f]{40})\s*$', workflow, re.M)[1]
    run = re.search(r"^\s+RPCS3_CORE_RUN_ID: '([0-9]+)'\s*$", workflow, re.M)
    require(run is not None, 'Missing explicit successful Core workflow run pin')
    validate_exact_pin(pin)
    if args.identity:
        identity = json.loads(args.identity.read_text())
        require(identity.get('host_commit') == pin, 'Downloaded Core identity belongs to another host commit')
        validate_core_input_identity(identity)
    print(f'PASS: exact Core inputs pinned to {pin}; independent host broker; ABI 30/client 1/stats 1/relay 1')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, IndexError) as error:
        raise SystemExit(str(error)) from error
