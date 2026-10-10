#!/usr/bin/env python3
"""Run the XITRIX v0.11 regressions imported with the Build 436 Core.

The five engine commits and their fixtures come verbatim from XITRIX/rpcs3
(GPL-2.0) and are part of the hash-verified canonical delta, under
rpcs3/ios/tests. Each runner extracts the production code from the
materialized source and executes it with test-only stubs. Three negative
controls show that the code before the import fails the same fixtures.
The fixtures prove host behaviour only, never iPhone rendering or frame rate.
"""
import argparse
import os
from pathlib import Path
import platform
import subprocess
import sys
import tempfile

UPSTREAM = '22f1152783cef1f7e04af7b1c895173e28fd5b03'
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('source', type=Path, help='hash-verified materialized RPCS3 source root')
parser.add_argument('--sanitize', action='store_true')
args = parser.parse_args()
root = args.source.resolve()
tests = root / 'rpcs3/ios/tests'
# The production lowerings and fixtures use AArch64 intrinsics, as upstream runs them.
assert platform.machine() in ('arm64', 'aarch64'), 'XITRIX v0.11 fixtures need an AArch64 host'
head = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
assert head == UPSTREAM, 'The materialized source must sit on the canonical base'
environment = dict(os.environ)
# The runners take one compiler path; the host macOS SDK comes from SDKROOT,
# never from the iPhoneOS SDK of the Core build.
environment.pop('SDKROOT', None)
if sdk := os.environ.get('HOST_MACOS_SDK'):
    environment['SDKROOT'] = sdk
sanitize = ['--sanitize'] if args.sanitize else []
failures = []


def run(script, *arguments, compiler=None):
    # Every runner executes; the test fails at the end if any of them failed.
    label = f'{script} {" ".join(map(str, arguments))}'.rstrip()
    print(f'== {label}', flush=True)
    env = dict(environment, CXX=str(compiler)) if compiler else environment
    result = subprocess.run([sys.executable, '-B', str(tests / script), *map(str, arguments), *sanitize],
                            env=env, timeout=600)
    if result.returncode:
        failures.append(label)


# 3dc496307: an equally recent complete source of the requested aspect wins.
run('run-framebuffer-source-tests.py')
run('run-framebuffer-source-tests.py', '--negative-control')
# 7137b41ae: the image pool is detached under its lock; the negative control
# runs the base VKTextureCache.cpp (not touched by the delta before this import).
run('run-vk-image-pool-tests.py')
with tempfile.TemporaryDirectory(prefix='rpcs3-v011-') as directory:
    original = Path(directory) / 'VKTextureCache.cpp'
    original.write_bytes(subprocess.check_output(
        ['git', '-C', str(root), 'show', UPSTREAM + ':rpcs3/Emu/RSX/VK/VKTextureCache.cpp']))
    run('run-vk-image-pool-tests.py', '--source', original, '--negative-control')
# 3ebf5c99f: rendering-overhead changes compared with the immutable pre-batch
# references (descriptors, fence wait, small quad indices, vertex layout).
run('run-minecraft-optimization-tests.py')
run('run-minecraft-vertex-tests.py')
# The extracted fence wait/signal with the fixture's portable wait engine, as
# upstream runs it outside macOS.
run('run-minecraft-fence-tests.py')
if platform.system() == 'Darwin':
    # The same fence code with the production wait engine (rpcs3/util/atomic.cpp,
    # untouched by the delta). Its allocator ends with fmt::throw_exception, whose
    # [[noreturn]] destructor the Xcode 16.4 clang of the Core build does not treat
    # as terminating: -Wreturn-type stays a warning for this compile only; every
    # fixture assertion is unchanged.
    with tempfile.TemporaryDirectory(prefix='rpcs3-v011-cxx-') as directory:
        wrapper = Path(directory) / 'clang++'
        real = os.environ.get('CXX', 'clang++')
        wrapper.write_text(f'#!/bin/sh\nexec "{real}" "$@" -Wno-error=return-type\n')
        wrapper.chmod(0o755)
        run('run-minecraft-fence-tests.py', '--native-atomic', compiler=wrapper)
run('run-minecraft-descriptor-tests.py')
run('run-minecraft-index-tests.py')
# 57ce3bf6a: divided vertex attributes keep the shader's integer range.
run('run-wrc4-vertex-range-tests.py')
# 395636f5a: alpha-to-one after emulated alpha-to-coverage.
run('run-rsx-alpha-coverage-tests.py')
run('run-rsx-alpha-coverage-tests.py', '--negative-control')
if failures:
    raise SystemExit('XITRIX v0.11 fixtures failed: ' + '; '.join(failures))
print('PASS XITRIX v0.11 imports: framebuffer source, image pool, rendering overhead, vertex range, alpha-to-one')
