#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Real file/VM tests. Synthetic workloads, not an iPhone or RPCS3 benchmark."""
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
import time

ROOT = Path(__file__).resolve().parent

def execute(command: list[str], report_dir: Path, name: str, timeout: int = 120) -> str:
    completed = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                               text=True, timeout=timeout)
    (report_dir / (name + '.log')).write_text(completed.stdout)
    print(name + ': ' + str(completed.returncode), flush=True)
    if completed.returncode:
        print(completed.stdout, file=sys.stderr)
        raise RuntimeError(f'{name} failed; no success report produced')
    return completed.stdout

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--ios-sdk', action='store_true', help='compile/link iOS ARM64 probe library; macOS only')
    args = parser.parse_args()
    out = args.output.resolve()
    if out == ROOT or ROOT in out.parents:
        raise SystemExit('Write evidence outside the prototype source directory')
    out.mkdir(parents=True, exist_ok=True)
    system = platform.system()
    if system not in ('Linux', 'Darwin'):
        raise SystemExit('This POSIX probe runs on Linux or macOS; compile iPhone target using Xcode')
    if args.ios_sdk and system != 'Darwin':
        raise SystemExit('--ios-sdk requires Xcode; no simulated pass on Linux')
    compiler = shutil.which('clang++')
    if not compiler:
        raise SystemExit('clang++ is required')
    libs = ['-lcompression', '-lz'] if system == 'Darwin' else ['-llz4', '-lz']
    common = [compiler, '-std=c++20', '-pthread', '-Wall', '-Wextra', '-Werror', '-I', str(ROOT)]
    sources = [str(ROOT / f) for f in ('Store.cpp', 'Metrics.cpp', 'ApplePressure.cpp')]
    start = time.monotonic()
    evidence = {
        'schema': 2, 'platform': system, 'machine': platform.machine(),
        'sourceCommit': os.environ.get('GITHUB_SHA'),
        'sourceInputSHA256': {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in sorted(ROOT.rglob('*')) if p.is_file() and '__pycache__' not in p.parts},
        'physicalIPhoneValidated': False, 'realRPCS3GameplayValidated': False,
        'kernelSwapPorted': False, 'nandReadLatencyProven': False,
        'latencyHistogramWindow': 256, 'residentPeakIsSampledNotContinuous': True,
        'storeRamIncludesRawAndCompressedButExcludesCodecWorkspaceAndOSFileCache': True,
        'faultsAndPressureAreInjectedInUnitTests': True,
        'realPOSIXFileRoundTrips': False, 'iosARM64Linked': False,
        'reusableExtentsTested': False, 'deferredOwnershipRetirementTested': False,
        'darwinPressureMonitorInstalledInBenchmark': system == 'Darwin',
        'iosRuntimeExecuted': False, 'benchmarks': [],
    }
    with tempfile.TemporaryDirectory(prefix='neoswap-storage-validation-') as temp:
        work = Path(temp)
        test = work / 'store-tests'
        execute(common + ['-O1', '-g', '-fsanitize=address,undefined', '-fno-omit-frame-pointer',
                          '-DNEOSWAP_STORAGE_TESTING'] + sources + [str(ROOT/'tests/store_test.cpp')]
                + libs + ['-o', str(test)], out, 'build-sanitized')
        execute([str(test), str(work/'private-cache')], out, 'fault-and-lifetime-tests')
        evidence['realPOSIXFileRoundTrips'] = True
        evidence['reusableExtentsTested'] = True
        evidence['deferredOwnershipRetirementTested'] = True
        bench = work / 'store-benchmark'
        execute(common + ['-O2'] + sources + [str(ROOT/'tests/benchmark.cpp')]
                + libs + ['-o', str(bench)], out, 'build-benchmark')
        cases = [('heap', 'raw', 64, 0), ('store', 'raw', 64, 0),
                 ('heap', 'compressed', 64, 0), ('store', 'compressed', 64, 0),
                 ('store', 'raw', 16, 16 * 1024**2)]
        for index, (mode, pattern, count, rate) in enumerate(cases):
            text = execute([str(bench), str(work/'private-cache'), mode, pattern, str(count), str(rate)],
                           out, f'benchmark-{index}-{mode}-{pattern}')
            result = json.loads(text)
            assert result['contentVerified'] and result['io_errors'] == 0
            if mode == 'store':
                assert result['disk_hits'] == count and result['restored_logical_bytes'] == count*1024**2
                assert result['allocated_file_bytes'] >= result['stored_payload_bytes'] > 0
                assert result['managed_ram_peak'] <= 9*1024**2
                assert result['logicalBytes'] > result['ramBudgetBytes']
            evidence['benchmarks'].append(result)
        if args.ios_sdk:
            sdk = subprocess.check_output(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], text=True).strip()
            ios_command = ['xcrun', '--sdk', 'iphoneos', 'clang++', '-std=c++20', '-O2',
                           '-Wall', '-Wextra', '-Werror', '-arch', 'arm64', '-isysroot', sdk,
                           '-miphoneos-version-min=18.0', '-I', str(ROOT)]
            execute(ios_command + sources + ['-dynamiclib', '-lcompression', '-lz',
                    '-install_name', '@rpath/NeoSwapStorageProbe.dylib',
                    '-o', str(out/'NeoSwapStorageProbe.dylib')], out, 'ios-arm64-link')
            execute(['xcrun', 'lipo', '-info', str(out/'NeoSwapStorageProbe.dylib')], out, 'ios-architecture')
            evidence['iosARM64Linked'] = True
    evidence['elapsedSeconds'] = round(time.monotonic()-start, 3)
    evidence['passed'] = True
    (out/'validation.json').write_text(json.dumps(evidence, indent=2) + '\n')
    print('PASS: real file/VM round trips and integrity; physical iPhone and gameplay remain unvalidated.')

if __name__ == '__main__':
    main()
