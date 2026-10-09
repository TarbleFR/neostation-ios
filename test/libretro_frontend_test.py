#!/usr/bin/env python3
"""Build and run the portable frontend behaviour tests of the libretro bridge (macOS).

Every test/libretro_host/frontend/*_test.m becomes one executable linked with
the portable frontend sources (geometry, input map, preferences, skins,
default skins, shader library) and the FRAMEWORKS below, built with -Werror.
Each executable runs with two arguments: an empty work directory of its own
and the repository root (for fixtures). It prints PASS / FAIL lines and
returns non-zero on failure. A test needing more link flags declares them on
a line of its own, for example: // LINK: -framework Metal
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / 'packages/libretro_internal_bridge/ios/Classes'
LIBRETRO = ROOT / 'packages/libretro_internal_bridge/ios/ThirdParty/include/libretro'
TESTS = ROOT / 'test/libretro_host/frontend'
PORTABLE_FRONTEND = (
    'LibretroGeometry.m',
    'LibretroInputMap.m',
    'LibretroFrontendStore.m',
    'LibretroSkin.m',
    'LibretroSkinLayout.m',
    'LibretroDefaultSkins.m',
    'LibretroShaderLibrary.m',
)
FRAMEWORKS = ('Foundation',)
LINK_MARKER = '// LINK:'


def extra_link_flags(test):
    flags = []
    for line in test.read_text(encoding='utf-8').splitlines():
        if line.startswith(LINK_MARKER):
            flags += line[len(LINK_MARKER):].split()
    return flags


def build(test, output):
    frameworks = [argument for name in FRAMEWORKS for argument in ('-framework', name)]
    command = ['clang', '-fobjc-arc', '-O1', '-Wall', '-Werror', '-I', str(CLASSES), '-I', str(LIBRETRO),
               *(str(CLASSES / name) for name in PORTABLE_FRONTEND), str(test),
               *frameworks, *extra_link_flags(test), '-o', str(output)]
    print('+', ' '.join(command), flush=True)
    return subprocess.run(command).returncode == 0


def main():
    if sys.platform != 'darwin':
        raise SystemExit('The libretro frontend tests run on macOS.')
    tests = sorted(TESTS.glob('*_test.m'))
    if not tests:
        raise SystemExit(f'No frontend test found in {TESTS.relative_to(ROOT)}')
    results = []
    with tempfile.TemporaryDirectory(prefix='libretro-frontend-') as temporary:
        temporary = Path(temporary)
        for test in tests:
            executable = temporary / test.stem
            if not build(test, executable):
                results.append((test.name, 'BUILD FAILED'))
                continue
            work = temporary / f'{test.stem}-work'
            work.mkdir()
            print(f'+ {executable.name}', flush=True)
            code = subprocess.run([str(executable), str(work), str(ROOT)]).returncode
            results.append((test.name, 'passed' if code == 0 else f'FAILED (exit {code})'))
    print('\nLibretro frontend tests:')
    for name, status in results:
        print(f'  {status:20} {name}')
    failed = [name for name, status in results if status != 'passed']
    if failed:
        raise SystemExit(f'{len(failed)} of {len(results)} frontend test(s) failed: ' + ', '.join(failed))
    print(f'All {len(results)} frontend test files passed')


if __name__ == '__main__':
    main()
