#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Execute the owned CPU swap engine; no physical iPhone or gameplay inference."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

from run_validation import execute

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(ROOT / 'build-utils'))
from validate_managed_swap_evidence import REQUIRED_INPUTS, validate
SOURCES = ('Store.cpp', 'Metrics.cpp', 'ManagedSwap.cpp', 'ManagedSwapABI.cpp')


def result_json(output: str) -> dict:
    return json.loads(next(line for line in reversed(output.splitlines()) if line.startswith('{')))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ios-sdk', action='store_true')
    args = parser.parse_args()
    out = args.output.resolve()
    if out == HERE or HERE in out.parents:
        raise SystemExit('Evidence must be outside the canonical source directory')
    out.mkdir(parents=True, exist_ok=True)
    apple = platform.system() == 'Darwin'
    if platform.system() not in ('Darwin', 'Linux') or (args.ios_sdk and not apple):
        raise SystemExit('POSIX execution required; --ios-sdk also requires Xcode')
    compiler = shutil.which('clang++') or shutil.which('c++')
    c_compiler = shutil.which('clang') or shutil.which('cc')
    if not compiler or not c_compiler:
        raise SystemExit('Real C and C++ compilers are required')
    sources = [str(HERE / name) for name in SOURCES]
    common = [compiler, '-std=c++20', '-pthread', '-Wall', '-Wextra', '-Werror', '-I', str(HERE)]
    libraries = ['-lcompression', '-lz'] if apple else ['-llz4', '-lz']
    compiler_version = subprocess.check_output([compiler, '--version'], text=True).splitlines()[0]
    # The unchanged Store uses compact statements and unchecked test-only
    # fault syscalls diagnosed by GCC, but not by the required Clang CI.
    # Keep every new unit strict; relax only these legacy object diagnostics.
    legacy_gcc = [] if 'clang' in compiler_version.lower() else [
        '-Wno-error=misleading-indentation', '-Wno-error=unused-result']
    report = {
        'schema': 1, 'sourceCommit': os.environ.get('GITHUB_SHA'),
        'platform': platform.system(), 'machine': platform.machine(),
        'compiler': compiler_version, 'legacyStoreGCCDiagnosticExceptions': legacy_gcc,
        'physicalIPhoneValidated': False, 'realRPCS3GameplayValidated': False,
        'kernelSwapPorted': False, 'automaticGuestPagingActivated': False,
        'iosARM64Linked': False, 'swiftInteropExecuted': False,
        'swiftIOSInteropTypechecked': False,
        'faultsAreInjected': True,
        'sanitizers': {'address': True, 'undefined': True,
                       'leakCheckDisabledByEnvironment': 'detect_leaks=0' in os.environ.get('ASAN_OPTIONS', '')},
        'managedBudgetIsMappedBytesNotGlobalPhysicalResidency': True,
        'osFileCacheAndUnrelatedProcessAllocationsExcludedFromManagedBudget': True,
    }
    with tempfile.TemporaryDirectory(prefix='neoswap-managed-proof-') as temporary:
        work = Path(temporary)
        cache = work / 'private-cache'
        cache.mkdir()
        execute([sys.executable, str(ROOT / 'build-utils/configure_neoswap_storage.py')],
                out, 'managed-canonical-host-copies')
        probe = work / 'public-header.c'
        probe.write_text('#include "ManagedSwapABI.h"\n#include "StorageABI.h"\n'
                         '_Static_assert(NEOSWAP_MANAGED_ABI_VERSION == 1, "managed ABI");\n'
                         '_Static_assert(NEOSWAP_STORAGE_ABI == 1, "retained shader ABI");\n'
                         'int main(void) { return NS_MANAGED_OK; }\n')
        execute([c_compiler, '-std=c11', '-Wall', '-Wextra', '-Werror', '-fsyntax-only',
                 '-I', str(HERE), str(probe)], out, 'managed-c11-public-header')
        sanitized = ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                     '-DNEOSWAP_STORAGE_TESTING']
        store_object = work / 'store-sanitized.o'
        execute(common + sanitized + legacy_gcc + ['-c', str(HERE / 'Store.cpp'), '-o', str(store_object)],
                out, 'managed-retained-store-build-sanitized')
        for name, source in (('core', 'managed_swap_test.cpp'), ('abi', 'managed_swap_abi_test.cpp')):
            binary = work / ('managed-' + name)
            execute(common + sanitized + sources[1:] + [str(store_object)] +
                    [str(HERE / 'tests' / source)] + libraries + ['-o', str(binary)],
                    out, 'managed-' + name + '-build-sanitized')
            report[name] = result_json(execute([str(binary), str(cache)], out, 'managed-' + name + '-run'))
            assert report[name]['passed'] is True
        core = report['core']
        assert core['logicalTouchedBytes'] >= 64 * 1024**2
        assert core['byteIdentityVerified'] and core['ramStorageRamCycleVerified']
        assert core['releasedOwnedBytes'] >= core['logicalTouchedBytes']
        assert core['restoredBytes'] >= core['logicalTouchedBytes']
        assert core['diskReadBytes'] > 0 and core['diskWriteBytes'] > 0
        assert 0 < core['managedMappedPeakBytes'] <= core['managedMappedLimitBytes']
        assert core['leaseAfterClose'] is True
        abi = report['abi']
        for field in ('cABIExecuted', 'contentVerified', 'leaseAfterContextDestroy',
                      'staleGenerationRejected', 'invalidArgumentsRejected'):
            assert abi[field] is True, field
        if apple:
            module = work / 'module'
            module.mkdir()
            shutil.copyfile(HERE / 'ManagedSwapABI.h', module / 'ManagedSwapABI.h')
            (module / 'module.modulemap').write_text(
                'module NeoSwapManaged { header "ManagedSwapABI.h" export * }\n')
            library = work / 'libNeoSwapManaged.dylib'
            execute(common + ['-O2'] + sources + libraries + ['-dynamiclib', '-o', str(library)],
                    out, 'managed-macos-library')
            swift_source = HERE / 'tests' / 'managed_swap_swift_test.swift'
            swift_binary = work / 'managed-swift'
            execute(['xcrun', 'swiftc', '-I', str(module), '-L', str(work), '-lNeoSwapManaged',
                     '-Xlinker', '-rpath', '-Xlinker', str(work), str(swift_source),
                     '-o', str(swift_binary)], out, 'managed-swift-build')
            swift = result_json(execute([str(swift_binary), str(cache)], out, 'managed-swift-run'))
            assert swift['passed'] and swift['swiftABIExecuted'] and swift['restoredContentVerified']
            assert swift['leaseAfterContextDestroy']
            report['swift'] = swift
            report['swiftInteropExecuted'] = True
            if args.ios_sdk:
                sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
                ios = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-std=c++20', '-O2', '-Wall', '-Wextra',
                       '-Werror', '-arch', 'arm64', '-isysroot', sdk, '-miphoneos-version-min=18.0',
                       '-I', str(HERE)]
                ios_library = out / 'NeoSwapManagedProbe.dylib'
                host_sources = [str(ROOT / 'packages/neo_swap/ios/Classes/Storage' / name) for name in SOURCES]
                execute(ios + host_sources + libraries + ['-dynamiclib', '-install_name',
                        '@rpath/NeoSwapManagedProbe.dylib', '-o', str(ios_library)], out, 'managed-ios-arm64-link')
                symbols = execute(['xcrun', 'nm', '-gU', str(ios_library)], out, 'managed-ios-symbols')
                for symbol in ('_NeoSwapManagedCreate', '_NeoSwapManagedCheckpoint',
                               '_NeoSwapManagedRead', '_NeoSwapManagedReleaseRead'):
                    assert symbol in symbols, symbol
                assert '_NeoSwapManagedTestInject' not in symbols
                report['iosARM64Linked'] = True
                sim_sdk = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], text=True).strip()
                execute(['xcrun', 'swiftc', '-typecheck', '-target', 'arm64-apple-ios18.0-simulator',
                         '-sdk', sim_sdk, '-I', str(module), str(swift_source)],
                        out, 'managed-swift-ios-typecheck')
                report['swiftIOSInteropTypechecked'] = True
    report['inputSHA256'] = {path: hashlib.sha256((ROOT / path).read_bytes()).hexdigest()
                             for path in sorted(REQUIRED_INPUTS)}
    report['passed'] = True
    validate(report, report['sourceCommit'], require_apple=apple and args.ios_sdk)
    (out / 'managed-swap.json').write_text(json.dumps(report, indent=2) + '\n')
    print('PASS owned CPU RAM/storage/RAM cycle, real file content and bounded mappings; no gameplay claim.')


if __name__ == '__main__':
    main()
