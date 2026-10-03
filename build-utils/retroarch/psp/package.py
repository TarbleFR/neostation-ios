#!/usr/bin/env python3
"""Validate and package the repository-pinned official iOS PPSSPP core."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import struct
import tarfile
import tempfile
import urllib.request
import zipfile

REPOSITORY = Path(__file__).resolve().parents[3]
PIN_PATH = REPOSITORY / 'native/retroarch/psp/pins.json'
PINS = json.loads(PIN_PATH.read_text())
LIBRETRO_EXPORTS = frozenset({
    '_retro_api_version', '_retro_cheat_reset', '_retro_cheat_set',
    '_retro_deinit', '_retro_get_memory_data', '_retro_get_memory_size',
    '_retro_get_region', '_retro_get_system_av_info', '_retro_get_system_info',
    '_retro_init', '_retro_load_game', '_retro_load_game_special', '_retro_reset',
    '_retro_run', '_retro_serialize', '_retro_serialize_size',
    '_retro_set_audio_sample', '_retro_set_audio_sample_batch',
    '_retro_set_controller_port_device', '_retro_set_environment',
    '_retro_set_input_poll', '_retro_set_input_state', '_retro_set_video_refresh',
    '_retro_unload_game', '_retro_unserialize',
})
ALLOWED_DEPENDENCIES = frozenset({
    '/usr/lib/libobjc.A.dylib',
    '/System/Library/Frameworks/OpenGLES.framework/OpenGLES',
    '/usr/lib/libz.1.dylib', '/usr/lib/libc++.1.dylib',
    '/usr/lib/libSystem.B.dylib',
})


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def require_identity(file: Path, pin: dict) -> None:
    if file.stat().st_size != pin['bytes']:
        raise ValueError(f'Pinned input length mismatch: {file.name}')
    with file.open('rb') as stream:
        actual = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual != pin['sha256']:
        raise ValueError(f'Pinned input SHA-256 mismatch: {file.name} ({actual})')


def safe_name(name: str) -> PurePosixPath:
    result = PurePosixPath(name)
    if result.is_absolute() or '..' in result.parts or '\\' in name:
        raise ValueError(f'Unsafe archive member: {name}')
    return result


def audit_macho(original: bytes) -> dict:
    """Read real ARM64/iOS imports, defined ABI exports and source version."""
    image = original
    if len(image) < 32:
        raise ValueError('Truncated PSP Mach-O')
    if struct.unpack_from('>I', image)[0] == 0xcafebabe:
        count = struct.unpack_from('>I', image, 4)[0]
        if count != 1:
            raise ValueError('PSP core must contain only one arm64 device slice')
        cpu, subtype, offset, length, alignment = struct.unpack_from('>5I', image, 8)
        if cpu != 0x0100000c or offset < 28 or offset + length > len(image):
            raise ValueError('Invalid PSP FAT arm64 slice')
        image = image[offset:offset + length]
    if len(image) < 32:
        raise ValueError('Truncated PSP arm64 slice')
    magic, cpu, subtype, kind, count, command_bytes, flags, reserved = struct.unpack_from('<8I', image)
    if magic != 0xfeedfacf or cpu != 0x0100000c or kind != 6:
        raise ValueError('PSP core must be an arm64 MH_DYLIB')
    if 32 + command_bytes > len(image):
        raise ValueError('Truncated PSP load commands')
    cursor = 32
    platform = None
    minimum = None
    dependencies = []
    install_name = None
    symbol_table = None
    segments = []
    for _ in range(count):
        if cursor + 8 > 32 + command_bytes:
            raise ValueError('Invalid PSP load command count')
        command, size = struct.unpack_from('<II', image, cursor)
        if size < 8 or cursor + size > 32 + command_bytes:
            raise ValueError('Invalid PSP load command size')
        if command == 0x32:
            if size < 24:
                raise ValueError('Truncated PSP build version')
            platform, minos, sdk = struct.unpack_from('<3I', image, cursor + 8)
            minimum = f'{minos >> 16}.{(minos >> 8) & 255}.{minos & 255}'
        elif command == 0x25:
            if size < 16:
                raise ValueError('Truncated PSP iOS version')
            platform = 2
            minos = struct.unpack_from('<I', image, cursor + 8)[0]
            minimum = f'{minos >> 16}.{(minos >> 8) & 255}.{minos & 255}'
        if command in {0xc, 0x18 | 0x80000000, 0x1f | 0x80000000, 0xd}:
            if size < 24:
                raise ValueError('Truncated PSP dylib command')
            start = struct.unpack_from('<I', image, cursor + 8)[0]
            if start < 24 or start >= size:
                raise ValueError('Invalid PSP dylib string offset')
            end = image.find(b'\0', cursor + start, cursor + size)
            if end < 0:
                raise ValueError('Unterminated PSP dylib string')
            value = image[cursor + start:end].decode('utf-8')
            if command == 0xd:
                install_name = value
            else:
                dependencies.append(value)
        if command == 0x19:
            if size < 72:
                raise ValueError('Truncated PSP segment')
            name, address, vm_size, file_offset, file_size = struct.unpack_from('<16s4Q', image, cursor + 8)
            if file_offset + file_size > len(image):
                raise ValueError('Truncated PSP segment file data')
            segments.append((address, vm_size, file_offset, file_size))
        if command == 2:
            if size < 24:
                raise ValueError('Truncated PSP symbol command')
            symbol_table = struct.unpack_from('<4I', image, cursor + 8)
        cursor += size
    if cursor != 32 + command_bytes:
        raise ValueError('PSP load command extent mismatch')
    if platform != 2:
        raise ValueError(f'PSP core must target iOS device, platform={platform}')
    if set(dependencies) != ALLOWED_DEPENDENCIES:
        raise ValueError(f'Unexpected PSP dependencies: {dependencies}')
    if install_name != '@rpath/ppsspp_libretro.dylib':
        raise ValueError(f'Unexpected PSP install name: {install_name}')
    if symbol_table is None:
        raise ValueError('PSP core has no auditable symbol table')
    symbols_offset, number, strings_offset, strings_size = symbol_table
    if symbols_offset + number * 16 > len(image) or strings_offset + strings_size > len(image):
        raise ValueError('Truncated PSP symbol table')
    exports = set()
    version_address = None
    for number_index in range(number):
        index, symbol_type, section, description, value = struct.unpack_from('<IBBHQ', image, symbols_offset + number_index * 16)
        if index >= strings_size:
            raise ValueError('Invalid PSP symbol string index')
        begin = strings_offset + index
        end = image.find(b'\0', begin, strings_offset + strings_size)
        if end < 0:
            raise ValueError('Unterminated PSP symbol name')
        name = image[begin:end].decode('utf-8')
        defined = (symbol_type & 0x0e) == 0x0e and section > 0
        if defined and (symbol_type & 1) and name.startswith('_retro_'):
            exports.add(name)
        if defined and name == '_PPSSPP_GIT_VERSION':
            version_address = value
    missing = LIBRETRO_EXPORTS - exports
    if missing:
        raise ValueError(f'Missing defined PSP ABI exports: {sorted(missing)}')

    def file_offset_for(address: int, length: int) -> int:
        for base, vm_size, offset, size in segments:
            if base <= address and address + length <= base + size:
                return offset + address - base
        raise ValueError('PSP source version points outside file-backed segments')

    if version_address is None:
        raise ValueError('PSP core has no auditable upstream source version')
    pointer = struct.unpack_from('<Q', image, file_offset_for(version_address, 8))[0]
    version_offset = file_offset_for(pointer, 1)
    version_end = image.find(b'\0', version_offset, version_offset + 80)
    if version_end < 0:
        raise ValueError('Unterminated PSP source version')
    version = image[version_offset:version_end].decode('ascii')
    if version != PINS['upstream']['embeddedGitVersion']:
        raise ValueError(f'PSP source version mismatch: {version}')
    return {'architectures': ['arm64'], 'platform': 'iOS', 'minimumOS': minimum,
            'installName': install_name, 'dependencies': dependencies,
            'libretroExports': sorted(exports), 'embeddedGitVersion': version,
            'sourceCommit': PINS['upstream']['commit']}


def read_core(archive: Path) -> tuple[bytes, dict]:
    require_identity(archive, PINS['coreArchive'])
    with zipfile.ZipFile(archive) as container:
        members = container.infolist()
        if len(members) != 1 or members[0].filename != PINS['coreArchive']['member']:
            raise ValueError('PSP archive contains unexpected members')
        for member in members:
            safe_name(member.filename)
            if stat.S_ISLNK(member.external_attr >> 16):
                raise ValueError('PSP core archive cannot contain links')
        core = container.read(PINS['coreArchive']['member'])
    if len(core) != PINS['coreArchive']['binaryBytes'] or digest(core) != PINS['coreArchive']['binarySha256']:
        raise ValueError('PSP binary identity mismatch')
    return core, audit_macho(core)


def download_assets(output: Path) -> Path:
    """The only network fetch is an immutable upstream commit archive."""
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists():
        require_identity(output, PINS['assetsSource'])
        return output
    temporary = output.with_suffix(output.suffix + '.part')
    try:
        with urllib.request.urlopen(PINS['assetsSource']['url'], timeout=45) as response, temporary.open('wb') as stream:
            shutil.copyfileobj(response, stream)
        require_identity(temporary, PINS['assetsSource'])
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def package(core_archive: Path, source_archive: Path, output: Path) -> dict:
    core, binary_audit = read_core(core_archive)
    require_identity(source_archive, PINS['assetsSource'])
    info = (REPOSITORY / PINS['info']['repositoryPath']).read_bytes()
    if digest(info) != PINS['info']['sha256']:
        raise ValueError('PSP metadata identity mismatch')
    if output.exists():
        raise ValueError(f'PSP output already exists: {output}')
    output.parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='retroarch-psp-', dir=output.parent))
    try:
        framework = work / 'Frameworks' / PINS['frameworkName']
        framework.mkdir(parents=True)
        executable = framework / PINS['executableName']
        executable.write_bytes(core)
        executable.chmod(0o755)
        (framework / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.neostation.libretro.ppsspp',
            'CFBundleExecutable': PINS['executableName'],
            'CFBundleName': 'PPSSPP', 'CFBundlePackageType': 'FMWK',
            'CFBundleVersion': '2026.9.28',
            'NeoUpstreamCommit': PINS['upstream']['commit'],
            'CFBundleShortVersionString': '1.0',
            'CFBundleSupportedPlatforms': ['iPhoneOS'], 'MinimumOSVersion': '12.0',
        }))
        resources = work / 'Resources' / 'RetroArchResources'
        assets_root = resources / 'system' / 'PPSSPP'
        licenses = resources / 'licenses'
        licenses.mkdir(parents=True)
        prefix = PINS['assetsSource']['archivePrefix'] + '/'
        with tarfile.open(source_archive, 'r:gz') as archive:
            for member in archive.getmembers():
                name = safe_name(member.name)
                if member.name == prefix.rstrip('/') and member.isdir():
                    continue
                if not member.name.startswith(prefix):
                    raise ValueError('Unexpected PSP source archive prefix')
                relative = member.name.removeprefix(prefix)
                if relative.startswith('assets/'):
                    if member.issym() or member.islnk() or member.isdev() or member.isfifo():
                        raise ValueError(f'PSP support assets contain a non-file member: {member.name}')
                    if not member.isfile():
                        continue
                    target = assets_root / relative.removeprefix('assets/')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    stream = archive.extractfile(member)
                    if stream is None:
                        raise ValueError('PSP asset extraction failed')
                    target.write_bytes(stream.read())
                if relative in PINS['upstream']['sourceFilesSha256']:
                    data = archive.extractfile(member).read()
                    if digest(data) != PINS['upstream']['sourceFilesSha256'][relative]:
                        raise ValueError(f'PSP upstream source audit mismatch: {relative}')
                if relative in ('LICENSE.TXT', 'README.md'):
                    (licenses / ('PPSSPP-' + relative)).write_bytes(archive.extractfile(member).read())
        for required in PINS['assetsSource']['requiredFiles']:
            if not (assets_root / required).is_file():
                raise ValueError(f'Required PPSSPP support asset missing: {required}')
        info_output = resources / 'info' / 'ppsspp_libretro.info'
        info_output.parent.mkdir(parents=True, exist_ok=True)
        info_output.write_bytes(info)
        metadata = {match.group(1): match.group(2) for match in re.finditer(
            r'^\s*(\w+)\s*=\s*"([^"\r\n]*)"', info.decode('utf-8'), re.M)}
        core_entry = {
            'id': 'ppsspp',
            'binary': f"Frameworks/{PINS['frameworkName']}/{PINS['executableName']}",
            'systemIds': PINS['systems'], 'title': 'PPSSPP', 'license': metadata['license'],
            'sha256': digest(core), 'info': 'info/ppsspp_libretro.info',
            'infoSha256': digest(info), 'savestate': metadata.get('savestate') == 'true',
            'cheats': metadata.get('cheats') == 'true',
            'supportedExtensions': metadata['supported_extensions'].split('|'),
            'firmware': [{'path': 'PPSSPP/ppge_atlas.zim',
                          'description': 'PPSSPP support assets', 'optional': False,
                          'providedBy': 'pinned-upstream-support-assets'}],
            'macho': binary_audit, 'qualification': 'requires-device-validation',
            'requiredOptions': PINS['runtime']['coreOptions'],
            'supplementaryInput': {
                'coreArchive': PINS['coreArchive']['repositoryPath'],
                'coreArchiveSha256': PINS['coreArchive']['sha256'],
                'repository': PINS['upstream']['repository'],
                'sourceCommit': PINS['upstream']['commit'],
                'assetsSourceSha256': PINS['assetsSource']['sha256'],
                'assetsIndexSha256': PINS['assetsSource']['assetsIndexSha256'],
            },
        }
        (work / 'ppsspp-core-entry.json').write_text(json.dumps(core_entry, indent=2) + '\n')
        assets_index = {str(file.relative_to(assets_root)): digest(file.read_bytes())
                        for file in sorted(assets_root.rglob('*')) if file.is_file()}
        if digest(json.dumps(assets_index, sort_keys=True, separators=(',', ':')).encode()) != PINS['assetsSource']['assetsIndexSha256']:
            raise ValueError('PPSSPP source asset index identity mismatch')
        (work / 'ppsspp-assets-index.json').write_text(json.dumps(assets_index, indent=2) + '\n')
        audit = {'success': True, 'coreArchiveSha256': PINS['coreArchive']['sha256'],
                 'binarySha256': digest(core), 'sourceArchiveSha256': PINS['assetsSource']['sha256'],
                 'infoSha256': digest(info), 'macho': binary_audit,
                 'assets': {'count': len(assets_index), 'bytes': sum(f.stat().st_size for f in assets_root.rglob('*') if f.is_file())},
                 'runtimeRequiredOptions': PINS['runtime']['coreOptions'],
                 'deviceQualified': False}
        (work / 'ppsspp-package-audit.json').write_text(json.dumps(audit, indent=2) + '\n')
        (licenses / 'PPSSPP-provenance.json').write_text(json.dumps(PINS, indent=2) + '\n')
        work.rename(output)
    except BaseException:
        shutil.rmtree(work, ignore_errors=True)
        raise
    return audit


def verify(output: Path) -> dict:
    core = (output / 'Frameworks' / PINS['frameworkName'] / PINS['executableName']).read_bytes()
    if digest(core) != PINS['coreArchive']['binarySha256']:
        raise ValueError('Packaged PSP core changed from the pinned input')
    audit_macho(core)
    entry = json.loads((output / 'ppsspp-core-entry.json').read_text())
    if (entry.get('id') != 'ppsspp' or entry.get('systemIds') != PINS['systems'] or
        entry.get('binary') != f"Frameworks/{PINS['frameworkName']}/{PINS['executableName']}" or
        entry.get('info') != 'info/ppsspp_libretro.info' or
        entry.get('sha256') != PINS['coreArchive']['binarySha256'] or
        entry.get('infoSha256') != PINS['info']['sha256'] or
        entry.get('requiredOptions') != PINS['runtime']['coreOptions'] or
        entry.get('cheats') is not False or
        entry.get('savestate') is not True or
        entry.get('qualification') != 'requires-device-validation' or
        entry.get('supportedExtensions') != ['elf', 'iso', 'cso', 'prx', 'pbp', 'chd'] or
        entry.get('supplementaryInput', {}).get('sourceCommit') != PINS['upstream']['commit']):
        raise ValueError('Packaged PSP manifest entry differs from pinned input')
    metadata = plistlib.loads((output / 'Frameworks' / PINS['frameworkName'] / 'Info.plist').read_bytes())
    if (metadata.get('CFBundleExecutable') != PINS['executableName'] or
        metadata.get('CFBundleSupportedPlatforms') != ['iPhoneOS'] or
        metadata.get('CFBundleVersion') != '2026.9.28' or
        metadata.get('NeoUpstreamCommit') != PINS['upstream']['commit']):
        raise ValueError('Packaged PSP framework metadata targets the wrong executable/platform')
    root = output / 'Resources' / 'RetroArchResources' / 'system' / 'PPSSPP'
    index = json.loads((output / 'ppsspp-assets-index.json').read_text())
    if digest(json.dumps(index, sort_keys=True, separators=(',', ':')).encode()) != PINS['assetsSource']['assetsIndexSha256']:
        raise ValueError('Packaged PSP asset index differs from pinned source')
    actual = {str(file.relative_to(root)): digest(file.read_bytes())
              for file in root.rglob('*') if file.is_file()}
    if actual != index:
        raise ValueError('Packaged PSP support assets changed or are missing')
    if any(not (root / required).is_file() for required in PINS['assetsSource']['requiredFiles']):
        raise ValueError('Packaged PSP lacks required support assets')
    info = output / 'Resources' / 'RetroArchResources' / 'info' / 'ppsspp_libretro.info'
    if digest(info.read_bytes()) != PINS['info']['sha256']:
        raise ValueError('Packaged PSP metadata changed')
    licenses = output / 'Resources' / 'RetroArchResources' / 'licenses'
    for name in ('LICENSE.TXT', 'README.md'):
        if digest((licenses / ('PPSSPP-' + name)).read_bytes()) != PINS['upstream']['sourceFilesSha256'][name]:
            raise ValueError(f'Packaged PSP upstream license/credits changed: {name}')
    if json.loads((licenses / 'PPSSPP-provenance.json').read_text()) != PINS:
        raise ValueError('Packaged PSP provenance differs from pinned input')
    frameworks = {p.name for p in (output / 'Frameworks').iterdir()}
    if frameworks != {PINS['frameworkName']}:
        raise ValueError('Supplementary PSP package contains unrelated cores')
    return {'success': True, 'core': 'ppsspp', 'binarySha256': digest(core),
            'assets': len(index), 'sourceCommit': PINS['upstream']['commit'], 'deviceQualified': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--core-archive', type=Path, default=REPOSITORY / PINS['coreArchive']['repositoryPath'])
    parser.add_argument('--assets-source', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--verify-only', action='store_true')
    args = parser.parse_args()
    if args.verify_only:
        report = verify(args.output)
    else:
        archive = args.assets_source or download_assets(args.output.parent / 'ppsspp-pinned-source.tar.gz')
        report = package(args.core_archive, archive, args.output)
        verify(args.output)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
