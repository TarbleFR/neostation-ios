#!/usr/bin/env python3
"""Package the libretro cores embedded in NeoStation iOS.

Downloads the official iOS ARM64 builds from the libretro buildbot (the
address RetroArch's pkg/apple/update-cores.sh uses), checks every Mach-O
(arm64, iOS platform, minimum OS, exported libretro API, dependencies),
wraps each core as `<id>_libretro.framework` without modifying its binary,
adds RetroArch's pinned MoltenVK framework and the PPSSPP system assets, and
writes identity.json plus a licence notice. Nothing here is compiled.

Usage: build_cores.py OUTPUT_DIR
"""
import datetime
import hashlib
import io
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST = json.loads((ROOT / 'build-utils/libretro/cores.json').read_text())
CPU_ARM64 = 0x0100000C
FAT_MAGIC = 0xCAFEBABE
MH_MAGIC_64 = 0xFEEDFACF
LC_LOAD_DYLIB = 0xC
LC_LOAD_WEAK_DYLIB = 0x80000018
LC_REEXPORT_DYLIB = 0x8000001F
LC_ID_DYLIB = 0xD
LC_RPATH = 0x8000001C
LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_IOS = 2
REQUIRED_EXPORTS = ('_retro_api_version', '_retro_init', '_retro_run', '_retro_load_game', '_retro_serialize')


def sha(data):
    return hashlib.sha256(data).hexdigest()


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'NeoStation-CI'})
    with urllib.request.urlopen(request, timeout=300) as response:
        return response.read(), {
            'lastModified': response.headers.get('Last-Modified'),
            'etag': response.headers.get('ETag'),
        }


def version(value):
    return '.'.join(str(part) for part in ((value >> 16) & 0xFFFF, (value >> 8) & 0xFF, value & 0xFF))


def thin_arm64(data):
    magic = struct.unpack('>I', data[:4])[0]
    if magic != FAT_MAGIC:
        return data
    count = struct.unpack('>I', data[4:8])[0]
    for index in range(count):
        cpu, _, offset, size, _ = struct.unpack('>iiIII', data[8 + index * 20:28 + index * 20])
        if cpu == CPU_ARM64:
            return data[offset:offset + size]
    raise ValueError('no arm64 slice')


def macho(data):
    magic, cpu, _, filetype, ncmds, _, _ = struct.unpack('<IiiIIII', data[:28])
    if magic != MH_MAGIC_64 or cpu != CPU_ARM64:
        raise ValueError('not a thin arm64 Mach-O')
    info = {'fileType': filetype, 'platform': None, 'minimumOS': None, 'dependencies': [], 'rpaths': [], 'id': None}
    offset = 32
    for _ in range(ncmds):
        command, size = struct.unpack('<II', data[offset:offset + 8])
        if command in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, LC_ID_DYLIB):
            name_offset = struct.unpack('<I', data[offset + 8:offset + 12])[0]
            name = data[offset + name_offset:offset + size].split(b'\0', 1)[0].decode()
            if command == LC_ID_DYLIB:
                info['id'] = name
            else:
                info['dependencies'].append(name)
        elif command == LC_RPATH:
            path_offset = struct.unpack('<I', data[offset + 8:offset + 12])[0]
            info['rpaths'].append(data[offset + path_offset:offset + size].split(b'\0', 1)[0].decode())
        elif command == LC_BUILD_VERSION:
            platform, minos = struct.unpack('<II', data[offset + 8:offset + 16])
            info['platform'], info['minimumOS'] = platform, version(minos)
        elif command == LC_VERSION_MIN_IPHONEOS:
            info['platform'], info['minimumOS'] = PLATFORM_IOS, version(struct.unpack('<I', data[offset + 8:offset + 12])[0])
        offset += size
    return info


def version_tuple(value):
    return tuple(int(part) for part in value.split('.'))


def exported_symbols(path):
    output = subprocess.run(['nm', '-gU', str(path)], check=True, capture_output=True, text=True).stdout
    return {line.split()[-1] for line in output.splitlines() if line.strip()}


def check_dependencies(name, info):
    for dependency in info['dependencies']:
        if dependency.startswith(('/usr/lib/', '/System/Library/')):
            continue
        if dependency == '@rpath/MoltenVK.framework/MoltenVK':
            continue
        raise ValueError(f'{name}: unsupported dependency {dependency}')


def framework_plist(identifier, executable, minimum):
    return plistlib.dumps({
        'CFBundleDevelopmentRegion': 'en',
        'CFBundleExecutable': executable,
        'CFBundleIdentifier': identifier,
        'CFBundleInfoDictionaryVersion': '6.0',
        'CFBundleName': executable,
        'CFBundlePackageType': 'FMWK',
        'CFBundleShortVersionString': '1.0',
        'CFBundleVersion': '1',
        'CFBundleSupportedPlatforms': ['iPhoneOS'],
        'MinimumOSVersion': minimum,
    })


def package_cores(output):
    listing = fetch(MANIFEST['buildbot'])[0].decode()
    available = set(re.findall(r'href="[^"]*/([^"/]+\.dylib\.zip)"', listing))
    frameworks = output / 'Frameworks'
    limit = version_tuple(MANIFEST['maximumCoreMinimumOS'])
    records = []
    for core in MANIFEST['cores']:
        identifier = core['id']
        candidates = [f'{identifier}_libretro_ios.dylib.zip', f'{identifier}_libretro.dylib.zip']
        archive_name = next((name for name in candidates if name in available), None)
        if archive_name is None:
            raise ValueError(f'{identifier}: not published on the buildbot')
        archive, headers = fetch(MANIFEST['buildbot'] + archive_name)
        member = archive_name[:-4]
        with zipfile.ZipFile(io.BytesIO(archive)) as bundle:
            if member not in bundle.namelist():
                raise ValueError(f'{identifier}: archive lacks {member}')
            original = bundle.read(member)
        binary = thin_arm64(original)
        info = macho(binary)
        if info['fileType'] != 6 or info['platform'] != PLATFORM_IOS or info['minimumOS'] is None:
            raise ValueError(f'{identifier}: not an iOS dylib ({info})')
        if version_tuple(info['minimumOS']) > limit:
            raise ValueError(f'{identifier}: requires iOS {info["minimumOS"]}')
        check_dependencies(identifier, info)
        executable = f'{identifier}_libretro'
        target = frameworks / f'{executable}.framework'
        target.mkdir(parents=True, exist_ok=True)
        (target / executable).write_bytes(binary)
        (target / executable).chmod(0o755)
        missing = [name for name in REQUIRED_EXPORTS if name not in exported_symbols(target / executable)]
        if missing:
            raise ValueError(f'{identifier}: missing libretro exports {missing}')
        bundle_id = 'com.neogamelab.neostation.libretro.' + identifier.replace('_', '-')
        (target / 'Info.plist').write_bytes(framework_plist(bundle_id, executable, info['minimumOS']))
        records.append({
            'id': identifier,
            'archive': archive_name,
            'url': MANIFEST['buildbot'] + archive_name,
            'archiveSha256': sha(archive),
            'sha256': sha(binary),
            'thinnedFromFat': binary is not original,
            'bytes': len(binary),
            'minimumOS': info['minimumOS'],
            'dependencies': info['dependencies'],
            'installName': info['id'],
            'license': core['license'],
            'source': core['source'],
            **headers,
        })
        print(f'{identifier}: {archive_name} {len(binary)} bytes iOS {info["minimumOS"]}', flush=True)
    return records


def package_moltenvk(output):
    molten = MANIFEST['moltenVK']
    target = output / 'Frameworks/MoltenVK.framework'
    target.mkdir(parents=True, exist_ok=True)
    base = f'https://raw.githubusercontent.com/libretro/RetroArch/{MANIFEST["retroarchRevision"]}/{molten["path"]}/'
    for name, expected in molten['files'].items():
        data = fetch(base + name)[0]
        if sha(data) != expected:
            raise ValueError(f'MoltenVK {name} hash {sha(data)} differs from the pin')
        (target / name).write_bytes(data)
    (target / 'MoltenVK').chmod(0o755)
    info = macho((target / 'MoltenVK').read_bytes())
    if info['platform'] != PLATFORM_IOS:
        raise ValueError('MoltenVK is not an iOS binary')
    return {'revision': MANIFEST['retroarchRevision'], 'files': molten['files'], 'minimumOS': info['minimumOS']}


def package_system_assets(output):
    records = []
    root = output / 'LibretroSystem'
    for asset in MANIFEST['systemAssets']:
        data, headers = fetch(asset['url'])
        with zipfile.ZipFile(io.BytesIO(data)) as bundle:
            names = bundle.namelist()
            prefix = '' if any(name.startswith(asset['name'] + '/') for name in names) else asset['name'] + '/'
            for entry in bundle.infolist():
                if entry.is_dir():
                    continue
                relative = Path(prefix + entry.filename)
                if relative.is_absolute() or '..' in relative.parts:
                    raise ValueError(f'unsafe asset path {entry.filename}')
                destination = root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(bundle.read(entry))
        if not (root / asset['required']).is_file():
            raise ValueError(f'{asset["name"]}: {asset["required"]} missing')
        records.append({'name': asset['name'], 'url': asset['url'], 'archiveSha256': sha(data), **headers})
    return records


def write_notices(output, cores, molten, assets):
    notices = output / 'Libretro-Licenses'
    notices.mkdir(parents=True, exist_ok=True)
    lines = [
        'NeoStation iOS embeds the following libretro cores, unmodified, as published',
        'by the libretro buildbot. Each core keeps its own licence; sources are listed',
        'with each entry. The exact binaries are identified by SHA-256 in identity.json.',
        '',
    ]
    for core in cores:
        lines.append(f'- {core["id"]}: {core["license"]} - {core["source"]} - sha256 {core["sha256"]}')
    lines += [
        '',
        f'- MoltenVK (Apache-2.0), from RetroArch {molten["revision"]} - https://github.com/KhronosGroup/MoltenVK',
        '- PPSSPP system assets - https://github.com/hrydgard/ppsspp',
        '- rcheevos (MIT) - https://github.com/RetroAchievements/rcheevos',
        '- libretro.h, libretro_vulkan.h (MIT) - https://github.com/libretro/RetroArch',
        '',
        'Full license reference texts and source-provenance limitations: Legal/Libretro/LIBRETRO_CORES.md.',
    ]
    (notices / 'LIBRETRO_CORES.txt').write_text('\n'.join(lines) + '\n')
    shutil.copytree(ROOT / 'assets/legal/libretro', notices, dirs_exist_ok=True)
    shutil.copy2(ROOT / 'packages/libretro_internal_bridge/ios/ThirdParty/rcheevos/LICENSE', notices / 'rcheevos-LICENSE.txt')
    shutil.copy2(ROOT / 'packages/libretro_internal_bridge/ios/ThirdParty/include/vulkan/LICENSE.md',
                 notices / 'Vulkan-Headers-LICENSE.md')


def main():
    output = Path(sys.argv[1]).resolve()
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)
    cores = package_cores(output)
    molten = package_moltenvk(output)
    assets = package_system_assets(output)
    write_notices(output, cores, molten, assets)
    files = {
        str(path.relative_to(output)): sha(path.read_bytes())
        for path in sorted(output.rglob('*')) if path.is_file()
    }
    identity = {
        'schema': 1,
        'host_commit': os.environ.get('GITHUB_SHA', ''),
        'retrieved': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'buildbot': MANIFEST['buildbot'],
        'cores': cores,
        'moltenVK': molten,
        'systemAssets': assets,
        'files': files,
        'compiled': False,
        'device_runtime_tested': False,
    }
    (output / 'identity.json').write_text(json.dumps(identity, indent=2) + '\n')
    print(f'Packaged {len(cores)} cores, MoltenVK and {len(assets)} system asset set(s) into {output}')


if __name__ == '__main__':
    main()
