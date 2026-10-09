#!/usr/bin/env python3
"""Compile every libretro bridge source and rcheevos file for iPhone (macOS).

Uses the iPhoneOS SDK with the podspec's flags, so a broken API use is caught
before the full delivery build. The Flutter plugin header is replaced by a
declaration stub; everything else is the real SDK.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'packages/libretro_internal_bridge/ios'
DEFINES = ('GLES_SILENCE_DEPRECATION=1', 'COREVIDEO_SILENCE_GL_DEPRECATION=1', 'VK_USE_PLATFORM_METAL_EXT=1',
           'VK_NO_PROTOTYPES=1', 'RC_CLIENT_SUPPORTS_HASH=1')


def main():
    if sys.platform != 'darwin':
        raise SystemExit('The iPhone syntax check runs on macOS.')
    sdk = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], check=True,
                         capture_output=True, text=True).stdout.strip()
    includes = [
        BRIDGE / 'Classes', BRIDGE / 'ThirdParty/include', BRIDGE / 'ThirdParty/include/libretro',
        BRIDGE / 'ThirdParty/rcheevos/include', BRIDGE / 'ThirdParty/rcheevos/src',
        ROOT / 'test/libretro_host/stubs',
    ]
    base = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', 'arm64-apple-ios17.4', '-isysroot', sdk,
            '-Wall', '-Wno-unused-function']
    for include in includes:
        base += ['-I', str(include)]
    for define in DEFINES:
        base += ['-D', define]
    sources = sorted((BRIDGE / 'Classes').glob('*.m')) + sorted((BRIDGE / 'ThirdParty/rcheevos/src').rglob('*.c'))
    failed = []
    with tempfile.TemporaryDirectory(prefix='libretro-ios-') as temporary:
        for source in sources:
            arguments = list(base)
            if source.suffix == '.m':
                arguments += ['-fobjc-arc', '-fmodules']
            arguments += ['-c', str(source), '-o', str(Path(temporary) / (source.stem + '.o'))]
            result = subprocess.run(arguments, capture_output=True, text=True)
            status = 'ok' if result.returncode == 0 else 'FAILED'
            print(f'{status:6} {source.relative_to(ROOT)}', flush=True)
            if result.stderr.strip():
                print(result.stderr, flush=True)
            if result.returncode != 0:
                failed.append(source.name)
    if failed:
        raise SystemExit('iPhone compilation failed: ' + ', '.join(failed))
    print(f'All {len(sources)} libretro bridge sources compile for iPhone')


if __name__ == '__main__':
    main()
