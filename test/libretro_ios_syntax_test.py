#!/usr/bin/env python3
"""Compile and link every libretro bridge source and rcheevos file for iPhone (macOS).

Uses the iPhoneOS SDK with the podspec's flags, so a broken API use is caught
before the full delivery build. The Flutter plugin header is replaced by a
declaration stub; everything else is the real SDK.

The objects are then linked into one dynamic library with the same SDK and
`nm -u` lists what it still needs from elsewhere. A symbol of the bridge
itself (a name containing "Libretro": its C functions and constants, and its
classes through OBJC_CLASS_$_Libretro... / OBJC_METACLASS_$_Libretro...) left
undefined means a declaration without a definition, which would otherwise
only fail the cold Xcode link of the delivery. Flutter symbols (declared by
the stub) and system symbols stay undefined on purpose: they are resolved by
the real application.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE = ROOT / 'packages/libretro_internal_bridge/ios'
TARGET = 'arm64-apple-ios17.4'
DEFINES = ('GLES_SILENCE_DEPRECATION=1', 'COREVIDEO_SILENCE_GL_DEPRECATION=1', 'VK_USE_PLATFORM_METAL_EXT=1',
           'VK_NO_PROTOTYPES=1', 'RC_CLIENT_SUPPORTS_HASH=1')
# The podspec's frameworks, plus ImageIO and CoreGraphics used by the skin
# code. Modules imported by the Objective-C sources are also auto-linked.
FRAMEWORKS = ('UIKit', 'Foundation', 'Metal', 'QuartzCore', 'AVFoundation', 'GameController', 'OpenGLES',
              'CoreVideo', 'Security', 'ImageIO', 'CoreGraphics')
BRIDGE_SYMBOL = 'Libretro'


def object_name(source):
    """One object per source, distinct even for equal file names in different folders."""
    return '_'.join(source.relative_to(BRIDGE).with_suffix('.o').parts)


def compile_sources(sdk, sources, directory):
    includes = [
        BRIDGE / 'Classes', BRIDGE / 'ThirdParty/include', BRIDGE / 'ThirdParty/include/libretro',
        BRIDGE / 'ThirdParty/rcheevos/include', BRIDGE / 'ThirdParty/rcheevos/src',
        ROOT / 'test/libretro_host/stubs',
    ]
    base = ['xcrun', '--sdk', 'iphoneos', 'clang', '-target', TARGET, '-isysroot', sdk,
            '-Wall', '-Wno-unused-function']
    for include in includes:
        base += ['-I', str(include)]
    for define in DEFINES:
        base += ['-D', define]
    objects = []
    failed = []
    for source in sources:
        output = directory / object_name(source)
        arguments = list(base)
        if source.suffix == '.m':
            arguments += ['-fobjc-arc', '-fmodules']
        arguments += ['-c', str(source), '-o', str(output)]
        result = subprocess.run(arguments, capture_output=True, text=True)
        status = 'ok' if result.returncode == 0 else 'FAILED'
        print(f'{status:6} {source.relative_to(ROOT)}', flush=True)
        if result.stderr.strip():
            print(result.stderr, flush=True)
        if result.returncode != 0:
            failed.append(source.name)
        objects.append(output)
    return objects, failed


def link(sdk, objects, output):
    arguments = ['xcrun', '--sdk', 'iphoneos', 'clang', '-dynamiclib', '-target', TARGET, '-isysroot', sdk,
                 '-fobjc-arc', *(str(item) for item in objects)]
    for framework in FRAMEWORKS:
        arguments += ['-framework', framework]
    arguments += ['-lz', '-Wl,-undefined,dynamic_lookup', '-o', str(output)]
    print('+ clang -dynamiclib ' + ' '.join(f'-framework {name}' for name in FRAMEWORKS)
          + f' -lz -Wl,-undefined,dynamic_lookup ({len(objects)} objects)', flush=True)
    result = subprocess.run(arguments, capture_output=True, text=True)
    if result.stdout.strip():
        print(result.stdout, flush=True)
    if result.stderr.strip():
        print(result.stderr, flush=True)
    if result.returncode != 0:
        raise SystemExit('iPhone link of the libretro bridge failed (see the linker output above)')


def undefined_symbols(library):
    result = subprocess.run(['xcrun', 'nm', '-u', str(library)], capture_output=True, text=True)
    if result.returncode != 0:
        print(result.stderr, flush=True)
        raise SystemExit('nm -u failed on the linked libretro bridge')
    names = set()
    for line in result.stdout.splitlines():
        line = line.strip()
        if line and not line.endswith(':'):
            names.add(line.split()[-1])
    return names


def main():
    if sys.platform != 'darwin':
        raise SystemExit('The iPhone syntax check runs on macOS.')
    sdk = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], check=True,
                         capture_output=True, text=True).stdout.strip()
    sources = sorted((BRIDGE / 'Classes').glob('*.m')) + sorted((BRIDGE / 'ThirdParty/rcheevos/src').rglob('*.c'))
    with tempfile.TemporaryDirectory(prefix='libretro-ios-') as temporary:
        directory = Path(temporary)
        objects, failed = compile_sources(sdk, sources, directory)
        if failed:
            raise SystemExit('iPhone compilation failed: ' + ', '.join(failed))
        print(f'All {len(sources)} libretro bridge sources compile for iPhone', flush=True)
        library = directory / 'liblibretro_internal_bridge.dylib'
        link(sdk, objects, library)
        undefined = undefined_symbols(library)
    missing = sorted(name for name in undefined if BRIDGE_SYMBOL in name)
    if missing:
        print('Bridge symbols used but defined by no source:', flush=True)
        for name in missing:
            print('  ' + name, flush=True)
        raise SystemExit(f'{len(missing)} libretro bridge symbol(s) declared and used but never defined')
    print(f'Linked {len(objects)} objects for iPhone: no bridge symbol left undefined '
          f'({len(undefined)} Flutter and system symbols left to the application)')


if __name__ == '__main__':
    main()
