#!/usr/bin/env python3
"""Independent, offline IPA and Mach-O validation; never simulates an iOS launch."""
from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import posixpath
import struct
import zipfile
from pathlib import Path

ARM64 = 0x0100000C
LOAD_DYLIB = {0xC, 0x80000018, 0x8000001F, 0x20, 0x80000023}
BRIDGE = {
    '_neostation_dolphin_initialize', '_neostation_dolphin_validate_image',
    '_neostation_dolphin_prepare_legacy_jit', '_neostation_dolphin_launch',
    '_neostation_dolphin_is_running', '_neostation_dolphin_set_paused',
    '_neostation_dolphin_stop', '_neostation_dolphin_save_identity',
    '_neostation_dolphin_menu_snapshot', '_neostation_dolphin_menu_apply',
    '_neostation_dolphin_state_snapshot', '_neostation_dolphin_state_operation',
    '_neostation_dolphin_performance_snapshot', '_neostation_dolphin_validate_wii_menu',
    '_neostation_dolphin_launch_wii_menu',
    '_neostation_dolphin_restart', '_neostation_dolphin_refresh_controllers',
    '_neostation_dolphin_touch_event', '_neostation_dolphin_release_touches',
}


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def macho(data: bytes) -> dict:
    """Read a real arm64 image, including dependency commands and symbol table."""
    if data[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        wide = data[:4] == b'\xca\xfe\xba\xbf'
        demand(len(data) >= 8, 'Truncated fat header')
        count = struct.unpack_from('>I', data, 4)[0]
        stride = 32 if wide else 20
        demand(0 < count <= 32 and len(data) >= 8 + stride * count, 'Invalid fat architecture table')
        for i in range(count):
            p = 8 + i * stride
            cpu = struct.unpack_from('>I', data, p)[0]
            if cpu == ARM64:
                offset, size = struct.unpack_from('>QQ' if wide else '>II', data, p + 8)
                demand(offset + size <= len(data), 'Truncated arm64 slice')
                return macho(data[offset:offset + size])
        raise ValueError('No arm64 slice')
    demand(len(data) >= 32 and data[:4] == b'\xcf\xfa\xed\xfe', 'Not a 64-bit little-endian Mach-O')
    _, cpu, subtype, filetype, ncmds, cmdbytes, _, _ = struct.unpack_from('<IiiIIIII', data)
    demand(cpu == ARM64, 'Image is not arm64')
    demand(ncmds <= 65536 and 32 + cmdbytes <= len(data), 'Truncated Mach-O commands')
    out = {'architecture': 'arm64', 'fileType': filetype, 'dependencies': [], 'rpaths': [],
           'id': None, 'definedSymbols': [], 'undefinedSymbols': [], 'codeSignature': False,
           'platform': None, 'minimumOS': None}
    table = None
    p = 32
    for _ in range(ncmds):
        demand(p + 8 <= 32 + cmdbytes, 'Truncated load command')
        cmd, size = struct.unpack_from('<II', data, p)
        demand(size >= 8 and p + size <= 32 + cmdbytes, 'Invalid load command size')
        if cmd in LOAD_DYLIB | {0xD, 0x8000001C}:
            demand(size >= 12, 'Truncated dylib/rpath command')
            off = struct.unpack_from('<I', data, p + 8)[0]
            demand(12 <= off < size, 'Invalid load command string offset')
            text = data[p + off:p + size].split(b'\0', 1)[0].decode('utf-8')
            if cmd == 0xD:
                out['id'] = text
            elif cmd == 0x8000001C:
                out['rpaths'].append(text)
            else:
                out['dependencies'].append({'path': text, 'weak': cmd == 0x80000018})
        elif cmd == 0x2:
            demand(size >= 24, 'Truncated symbol-table command')
            table = struct.unpack_from('<IIII', data, p + 8)
        elif cmd == 0x1D:
            demand(size >= 16, 'Truncated code-signature command')
            off, length = struct.unpack_from('<II', data, p + 8)
            out['codeSignature'] = length > 0 and off + length <= len(data)
        elif cmd == 0x32:
            demand(size >= 24, 'Truncated build-version command')
            platform, version = struct.unpack_from('<II', data, p + 8)
            out['platform'] = platform
            out['minimumOS'] = f'{version >> 16}.{(version >> 8) & 255}.{version & 255}'
        elif cmd == 0x25:
            version = struct.unpack_from('<I', data, p + 8)[0]
            out['platform'] = 2
            out['minimumOS'] = f'{version >> 16}.{(version >> 8) & 255}.{version & 255}'
        p += size
    demand(p == 32 + cmdbytes, 'Mach-O command size mismatch')
    if table:
        symoff, nsyms, stroff, strsize = table
        demand(symoff + 16 * nsyms <= len(data) and stroff + strsize <= len(data), 'Truncated symbol table')
        for i in range(nsyms):
            stringidx, kind, _, _, _ = struct.unpack_from('<IBBHQ', data, symoff + 16 * i)
            if kind & 0xE0 or not kind & 1 or stringidx == 0:
                continue
            demand(stringidx < strsize, 'Symbol string offset out of range')
            start = stroff + stringidx
            end = data.find(b'\0', start, stroff + strsize)
            demand(end >= start, 'Unterminated Mach-O symbol name')
            name = data[start:end].decode('utf-8', errors='replace')
            out['undefinedSymbols' if kind & 0x0E == 0 else 'definedSymbols'].append(name)
    return out


def validate(ipa: Path) -> dict:
    demand(ipa.is_file() and ipa.stat().st_size > 0, 'IPA is absent or empty')
    with zipfile.ZipFile(ipa) as z:
        demand(z.testzip() is None, 'IPA ZIP CRC validation failed')
        names = z.namelist()
        demand(len(names) == len(set(names)), 'Duplicate ZIP member names')
        for name in names:
            demand(not name.startswith('/') and '..' not in name.split('/'), f'Unsafe ZIP entry: {name}')
            demand(name.count('Payload/') <= 1, 'Nested parasite Payload')
            demand('DolphiniOS.app' not in name, 'External DolphiniOS bundle found')
        apps = {n.split('/')[1] for n in names if n.startswith('Payload/') and len(n.split('/')) > 2 and n.split('/')[1].endswith('.app')}
        demand(apps == {'NeoStation.app'}, f'Expected only Payload/NeoStation.app, found {apps}')
        app = 'Payload/NeoStation.app'
        for name in names:
            demand(not any(p.endswith('.app') for p in name.split('/')[2:]), 'Nested application bundle')
        info = plistlib.loads(z.read(app + '/Info.plist'))
        demand(info['CFBundleIdentifier'] == 'com.neogamelab.neostation', 'Wrong NeoStation bundle ID')
        main = app + '/' + info['CFBundleExecutable']
        helper_infos = [n for n in names if n.endswith('/DolphinJITHelper.appex/Info.plist')]
        demand(len(helper_infos) == 1, 'Expected exactly one DolphinJITHelper')
        helper_info = plistlib.loads(z.read(helper_infos[0]))
        helper_root = posixpath.dirname(helper_infos[0])
        demand(helper_root == app + '/PlugIns/DolphinJITHelper.appex', 'Helper must be embedded in PlugIns')
        demand(helper_info['CFBundleIdentifier'] == info['CFBundleIdentifier'] + '.dolphinjithelper', 'Helper ID is inconsistent')
        demand(bool(helper_info.get('NSExtension', {}).get('NSExtensionPrincipalClass')), 'Helper principal class is missing')
        helper = helper_root + '/' + helper_info['CFBundleExecutable']
        core = app + '/Frameworks/DolphinCore.framework/DolphinCore'
        stik = app + '/Frameworks/StikJIT.framework/StikJIT'
        demand([n for n in names if n.endswith('/StikJIT.framework/StikJIT')] == [stik], 'StikJIT must have one shared host copy')
        core_info = plistlib.loads(z.read(posixpath.dirname(core) + '/Info.plist'))
        stik_info = plistlib.loads(z.read(posixpath.dirname(stik) + '/Info.plist'))
        demand(core_info['CFBundlePackageType'] == 'FMWK', 'Invalid Dolphin framework plist')
        demand(stik_info['CFBundleShortVersionString'] == '1.5.0', 'Wrong StikJIT version')
        images = {}
        for name in names:
            if name.endswith('/'):
                continue
            with z.open(name) as entry:
                magic = entry.read(4)
            if magic in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
                image = macho(z.read(name))
                demand(image['platform'] == 2, f'Non-iOS Mach-O embedded: {name}')
                images[name] = image
        for name in (main, helper, core, stik):
            demand(name in images, f'Required arm64 executable is missing: {name}')
            demand((z.getinfo(name).external_attr >> 16) & 0o111 != 0, f'Executable mode missing: {name}')
        demand(BRIDGE.issubset(set(images[core]['definedSymbols'])), 'Actual Dolphin bridge exports are missing')
        demand(z.getinfo(core).file_size > 1024 * 1024, 'Dolphin core image is implausibly small')
        core_symbols = images[core]['definedSymbols']
        for token in ('BootCore', 'JitArm64'):
            demand(any(token in s for s in core_symbols), f'Real Dolphin implementation symbol missing: {token}')
        demand(any(d['path'] == '@rpath/StikJIT.framework/StikJIT' for d in images[helper]['dependencies']), 'Helper does not dynamically link StikJIT')
        demand(any(d['path'] == '@rpath/DolphinCore.framework/DolphinCore'
                   for name, image in images.items() if name != core
                   for d in image['dependencies']), 'No host image links DolphinCore (self-ID is not evidence)')
        for resource in ('Sys/GC/dsp_rom.bin', 'Sys/GC/dsp_coef.bin'):
            demand(app + '/' + resource in names, f'Missing Dolphin system resource: {resource}')
        demand(any(n.startswith(app + '/Sys/Wii/') for n in names), 'Wii system resources absent')
        touch_bundle = app + '/Frameworks/dolphin_internal_bridge.framework/'
        bridge_image = images.get(touch_bundle + 'dolphin_internal_bridge')
        demand(bridge_image is not None, 'Dolphin native UI bridge missing')
        demand(any('DolphinRecordingController' in symbol for symbol in bridge_image['definedSymbols']),
               'Native recording controller missing from the shipped executable')
        for framework in ('ReplayKit', 'AVFoundation', 'CoreImage'):
            demand(any('/' + framework + '.framework/' in dependency['path']
                       for dependency in bridge_image['dependencies']),
                   f'Native recording framework not linked: {framework}')
        for layout in ('TCGameCubePad', 'TCWiiPad', 'TCClassicWiiPad'):
            nib = touch_bundle + layout + '.nib'
            demand(nib in names or any(n.startswith(nib + '/') for n in names),
                   f'Original DolphiniOS touchscreen layout missing from its Swift bundle: {layout}')
        for button in ('gcpad_a', 'wiimote_a', 'classic_a', 'nunchuk_c', 'gcwii_joystick'):
            demand(touch_bundle + button + '@2x.png' in names, f'Touchscreen artwork missing: {button}')
        schemes = set(info.get('LSApplicationQueriesSchemes', []))
        demand({'retroarch', 'shortcuts', 'armsx2', 'melonx'} <= schemes, 'Existing URL query schemes were removed')
        demand(not schemes & {'dolphin', 'dolphinios', 'dolphin-emu'}, 'External Dolphin query scheme found')
        dependency_checks = []
        system_dependencies = set()
        for name, image in images.items():
            executable_dir = helper_root if name.startswith(helper_root + '/') else app
            loader_dir = posixpath.dirname(name)
            def expand(value: str) -> str:
                return posixpath.normpath(value.replace('@executable_path', executable_dir).replace('@loader_path', loader_dir))
            rpaths = [expand(r) for r in image['rpaths']]
            root_image = images[helper] if executable_dir == helper_root else images[main]
            for r in root_image['rpaths']:
                rpaths.append(posixpath.normpath(r.replace('@executable_path', executable_dir).replace('@loader_path', executable_dir)))
            for dep in image['dependencies']:
                value = dep['path']
                if value.startswith(('/System/Library/', '/usr/lib/')):
                    system_dependencies.add(value)
                    continue
                if value.startswith('@rpath/'):
                    suffix = value[len('@rpath/'):]
                    candidates = [posixpath.normpath(r + '/' + suffix) for r in rpaths]
                elif value.startswith(('@loader_path/', '@executable_path/')):
                    candidates = [expand(value)]
                else:
                    raise ValueError(f'Non-relocatable Mach-O dependency in {name}: {value}')
                resolved = next((p for p in candidates if p in images), None)
                system = next((p for p in candidates if p.startswith(('/usr/lib/', '/System/Library/'))), None)
                if system:
                    system_dependencies.add(system)
                demand(resolved is not None or system is not None, f'Unresolved dependency: {name} -> {value}; paths={rpaths}')
                dependency_checks.append({'image': name, 'dependency': value, 'resolved': resolved or system})
        summary_images = {}
        for name, image in images.items():
            summary_images[name] = {k: v for k, v in image.items() if k not in ('definedSymbols', 'undefinedSymbols')}
            summary_images[name]['definedSymbolCount'] = len(image['definedSymbols'])
        return {
            'ipa': ipa.name, 'bytes': ipa.stat().st_size,
            'sha256': file_sha256(ipa),
            'zipIntegrity': 'passed', 'mainApplicationCount': 1,
            'requiredBridgeExports': sorted(BRIDGE), 'machOImages': summary_images,
            'resolvedDependencies': dependency_checks, 'systemDependencies': sorted(system_dependencies),
            'systemDependenciesOnDevice': 'OS-provided; runtime dyld validation still requires an iOS device',
            'signatureState': 'main contains a code signature; certificate trust not tested' if images[main]['codeSignature'] else 'unsigned; sideload signing required',
            'deviceLaunchValidated': False,
            'structuralValidation': 'passed',
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    report = validate(args.ipa)
    text = json.dumps(report, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.write_text(text, encoding='utf-8')
    print(json.dumps({k: report[k] for k in ('ipa', 'bytes', 'sha256', 'structuralValidation', 'signatureState', 'deviceLaunchValidated')}, indent=2))


if __name__ == '__main__':
    main()
