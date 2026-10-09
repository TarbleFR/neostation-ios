#!/usr/bin/env python3
"""Compile and render every NeoStation shader preset with Metal (macOS).

Builds test/libretro_host/shader_test.m with LibretroShaderLibrary.m and runs
it: catalog checks, then for the plain path and each preset a compilation with
LibretroShaderLanguageVersion, a render pipeline checked by reflection and
control renders. When the runner has no Metal device, every complete MSL
source is compiled offline with the Metal toolchain instead and the run says
that no rendering was checked. With neither, the test fails.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / 'packages/libretro_internal_bridge/ios/Classes'
NO_DEVICE = 3  # exit code of shader_test when MTLCreateSystemDefaultDevice() is nil
SOURCES = 10  # plain path + 9 presets
STANDARDS = ('metal2.4', 'macos-metal2.4')


def run(*arguments):
    print('+', ' '.join(str(argument) for argument in arguments), flush=True)
    subprocess.run([str(argument) for argument in arguments], check=True)


def metal(source, standard):
    result = subprocess.run(['xcrun', '-sdk', 'macosx', 'metal', f'-std={standard}', '-c', str(source),
                             '-o', str(source.with_suffix('.air'))], capture_output=True, text=True)
    return result.returncode == 0, (result.stdout + result.stderr).strip()


def language_standard(probe):
    log = ''
    for standard in STANDARDS:
        compiled, log = metal(probe, standard)
        if compiled:
            return standard, log
    return None, log


def offline_compile(harness, temporary):
    sources = temporary / 'msl'
    run(harness, '--dump', sources)
    files = sorted(sources.glob('*.metal'))
    if len(files) != SOURCES:
        raise SystemExit(f'Expected {SOURCES} shader sources, found {len(files)}')
    probe = sources / 'passthrough.metal'
    standard, log = language_standard(probe)
    if standard is None:
        print(log, flush=True)
        print('+ xcodebuild -downloadComponent MetalToolchain', flush=True)
        subprocess.run(['xcodebuild', '-downloadComponent', 'MetalToolchain'], check=False)
        standard, log = language_standard(probe)
    if standard is None:
        raise SystemExit('No Metal device and no offline Metal compiler:\n' + log)
    failed = []
    for source in files:
        compiled, log = metal(source, standard)
        print(f'{"ok" if compiled else "FAILED":6} {source.name} (-std={standard})', flush=True)
        if log:
            print(log, flush=True)
        if not compiled:
            failed.append(source.name)
    if failed:
        raise SystemExit('Offline Metal compilation failed: ' + ', '.join(failed))
    print('NO METAL DEVICE: offline compile only, no rendering checked', flush=True)


def main():
    if sys.platform != 'darwin':
        raise SystemExit('The shader test runs on macOS.')
    with tempfile.TemporaryDirectory(prefix='libretro-shaders-') as temporary:
        temporary = Path(temporary)
        harness = temporary / 'libretro_shader_test'
        run('clang', '-fobjc-arc', '-O1', '-Wall', '-mmacosx-version-min=13.0', '-I', CLASSES,
            CLASSES / 'LibretroShaderLibrary.m', ROOT / 'test/libretro_host/shader_test.m',
            '-framework', 'Foundation', '-framework', 'Metal', '-o', harness)
        print('+', harness, flush=True)
        result = subprocess.run([str(harness)])
        if result.returncode == NO_DEVICE:
            offline_compile(harness, temporary)
        elif result.returncode != 0:
            raise SystemExit(f'Shader test failed (exit code {result.returncode})')


if __name__ == '__main__':
    main()
