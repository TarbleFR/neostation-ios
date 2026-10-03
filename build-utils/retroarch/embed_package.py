#!/usr/bin/env python3
"""Embed a validated RetroArch package into one already-built NeoStation app.

This post-build step owns only RetroArch files. It does not relink the host,
modify other emulator targets, rewrite core Mach-O images or sign their bytes.
The resulting unsigned IPA must have all nested binaries resigned by the user's
installation tool; original source IPA signatures are not a host signature.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import struct
import tempfile
import tarfile
import zipfile

from package_ipa import PINS, macho

PUBLIC_ABI = '_NeoRetroArch_GetAPI'
FRONTEND_NAME = 'Frameworks/libRetroArchCore.dylib'
USER_DIRECTORIES = {'system', 'games', 'saves', 'states'}


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def read_json(path: Path) -> dict:
    value = json.loads(path.read_text(encoding='utf-8'))
    demand(isinstance(value, dict), f'Expected JSON object: {path}')
    return value


def file_hash(path: Path) -> str:
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def tree_files(root: Path) -> dict[str, Path]:
    """Never follow a symlink supplied by a downloaded artifact."""
    demand(root.is_dir() and not root.is_symlink(), f'Missing/unsafe directory: {root}')
    files = {}
    for path in root.rglob('*'):
        demand(not path.is_symlink(), f'Symlink in package: {path}')
        demand(path.is_dir() or path.is_file(), f'Unsupported filesystem entry: {path}')
        if path.is_file():
            files[path.relative_to(root).as_posix()] = path
    return files


def frontend_symbols(data: bytes) -> tuple[set[str], set[str]]:
    """Read public definitions/imports from the source-built arm64 symbol table."""
    demand(len(data) >= 32 and struct.unpack_from('<I', data)[0] == 0xfeedfacf,
           'Frontend must be one thin arm64 device Mach-O')
    count, command_bytes = struct.unpack_from('<II', data, 16)
    cursor = 32
    table = None
    for _ in range(count):
        demand(cursor + 8 <= 32 + command_bytes, 'Truncated frontend load command')
        command, size = struct.unpack_from('<II', data, cursor)
        demand(size >= 8 and cursor + size <= 32 + command_bytes, 'Invalid frontend load command')
        if command == 2:
            demand(size >= 24 and table is None, 'Missing/duplicate frontend symbol table')
            table = struct.unpack_from('<IIII', data, cursor + 8)
        cursor += size
    demand(cursor == 32 + command_bytes and table is not None, 'Frontend ABI symbol table unavailable')
    offset, count, strings, string_bytes = table
    demand(offset + 16 * count <= len(data) and strings + string_bytes <= len(data),
           'Truncated frontend symbol table')
    definitions, imports = set(), set()
    for i in range(count):
        index, kind, section, description, value = struct.unpack_from('<IBBHQ', data, offset + 16 * i)
        if kind & 0xe0 or not kind & 1 or kind & 0x10 or not index:
            continue  # Debug, local and private-external definitions are not exported.
        demand(index < string_bytes, 'Frontend symbol string offset outside table')
        end = data.find(b'\0', strings + index, strings + string_bytes)
        demand(end >= strings + index, 'Unterminated frontend symbol')
        name = data[strings + index:end].decode('utf-8')
        (imports if kind & 0x0e == 0 else definitions).add(name)
    return definitions, imports


def supplemental_assets(package: Path, pins: dict) -> set[str]:
    allowed = set()
    for core in pins['cores']:
        supplemental = core.get('supplementaryInput')
        if not supplemental:
            continue
        demand(core['id'] == 'ppsspp', 'Unrecognized supplementary core asset format')
        index = read_json(package / 'ppsspp-assets-index.json')
        digest = sha256(json.dumps(index, sort_keys=True, separators=(',', ':')).encode())
        demand(digest == supplemental['assetsIndexSha256'], 'Supplementary PSP asset index differs from pins')
        for relative, expected in index.items():
            path = PurePosixPath(relative)
            demand(not path.is_absolute() and '..' not in path.parts and '\\' not in relative,
                   'Unsafe supplementary PSP asset path')
            destination = 'system/PPSSPP/' + relative
            demand(file_hash(package / 'Resources' / 'RetroArchResources' / destination) == expected,
                   f'Supplementary PSP support asset changed: {relative}')
            allowed.add(destination)
        audit = read_json(package / 'ppsspp-package-audit.json')
        demand(audit.get('success') is True and audit.get('binarySha256') == core['sha256'] and
               audit.get('coreArchiveSha256') == supplemental['coreArchiveSha256'] and
               audit.get('sourceArchiveSha256') == supplemental['assetsSourceSha256'] and
               audit.get('infoSha256') == core['infoSha256'] and
               audit.get('runtimeRequiredOptions') == core['forcedOptions'],
               'Supplementary PSP provenance/profile differs from pins')
        source = package / 'ppsspp-corresponding-source.tar.gz'
        demand(source.is_file() and file_hash(source) == supplemental['assetsSourceSha256'],
               'Supplementary PSP corresponding source differs from pinned upstream archive')
    return allowed


def package_files(package: Path, pins: dict) -> dict[str, Path]:
    framework_files = tree_files(package / 'Frameworks')
    resources = tree_files(package / 'Resources' / 'RetroArchResources')
    expected_frameworks = {PurePosixPath(core['binary']).parts[1] for core in pins['cores']}
    actual_frameworks = {path.name for path in (package / 'Frameworks').iterdir() if path.is_dir()}
    demand(actual_frameworks == expected_frameworks, 'Package contains missing or uncurated core frameworks')
    loose = {path.name for path in (package / 'Frameworks').iterdir() if path.is_file()}
    demand(loose == {'libRetroArchCore.dylib'}, 'Package contains unexpected loose frontend/core binaries')
    support_assets = supplemental_assets(package, pins)
    for relative in resources:
        first = PurePosixPath(relative).parts[0]
        demand(first not in USER_DIRECTORIES or relative in support_assets,
               f'Package must not ship user BIOS/game/save files: {relative}')
        demand(not any(part.endswith('.app') for part in PurePosixPath(relative).parts),
               'Standalone application nested in RetroArch resources')
    result = {'Frameworks/' + name: path for name, path in framework_files.items()}
    result.update({'RetroArchResources/' + name: path for name, path in resources.items()})
    result['retroarch-core-manifest.json'] = package / 'Resources' / 'retroarch-core-manifest.json'
    return result


def validate_package(package: Path, frontend_host_commit: str, pins: dict | None = None) -> dict:
    pins = pins or PINS
    demand(package.is_dir() and not package.is_symlink(), 'Native package path must be a real directory')
    tree_files(package)
    # A partial/moving artifact cannot silently stand in for the pinned stage1 output.
    demand(read_json(package / 'source-pins.json') == pins, 'Native package source pins differ from checkout')
    manifest = read_json(package / 'Resources' / 'retroarch-core-manifest.json')
    demand(manifest.get('sourceIpa') == pins['sourceIpa'], 'Embedded core donor identity differs from pins')
    demand(manifest.get('frontend') == pins['frontend'], 'Embedded frontend source identity differs from pins')
    entries = manifest.get('cores')
    demand(isinstance(entries, list) and len(entries) == len(pins['cores']), 'Incorrect curated core count')
    by_id = {entry['id']: entry for entry in entries}
    demand(len(by_id) == len(entries) and set(by_id) == {core['id'] for core in pins['cores']},
           'Duplicate, missing or uncurated core identifier')
    for core in pins['cores']:
        entry = by_id[core['id']]
        for key, value in core.items():
            if key == 'title':
                continue  # Packaging shortens display titles; identity/routing stays pinned.
            demand(entry.get(key) == value, f'Core metadata differs from pins: {core["id"]}/{key}')
        relative = PurePosixPath(core['binary'])
        demand(not relative.is_absolute() and '..' not in relative.parts and len(relative.parts) == 3
               and relative.parts[0] == 'Frameworks' and relative.parts[1].endswith('.libretro.framework'),
               f'Unsafe core binary path: {relative}')
        binary = package.joinpath(*relative.parts)
        demand(file_hash(binary) == core['sha256'], f'Core binary identity mismatch: {core["id"]}')
        macho(binary.read_bytes())
        info = package / 'Resources' / 'RetroArchResources' / core['info']
        demand(file_hash(info) == core['infoSha256'], f'Core info identity mismatch: {core["id"]}')
    info_files = {path.name for path in (package / 'Resources' / 'RetroArchResources' / 'info').glob('*.info')}
    demand(info_files == {PurePosixPath(core['info']).name for core in pins['cores']},
           'Package includes missing or uncurated core metadata')
    files = package_files(package, pins)
    frontend = package / FRONTEND_NAME
    data = frontend.read_bytes()
    metadata = macho(data)
    demand(metadata['installName'] == '@rpath/libRetroArchCore.dylib', 'Frontend runtime path differs from host loader')
    definitions, imports = frontend_symbols(data)
    demand(definitions == {PUBLIC_ABI}, f'Unexpected frontend public exports: {sorted(definitions)}')
    demand('_UIApplicationMain' not in imports, 'Frontend imports a second UIApplication entry')
    report = read_json(package / 'frontend-validation.json')
    demand(report.get('success') is True and report.get('sourceBuild') is True and report.get('standaloneEntry') is False,
           'Missing source-built hosted-frontend validation')
    demand(report.get('hostCommit') == frontend_host_commit, 'Frontend artifact was built from a different host commit')
    demand(report.get('frontendCommit') == pins['frontend']['commit'] and
           report.get('sourceIpaSha256') == pins['sourceIpa']['sha256'], 'Frontend report references different sources')
    demand(report.get('frontendSha256') == sha256(data), 'Frontend binary differs from its build report')
    demand(report.get('frontendMacho') == metadata, 'Frontend Mach-O metadata differs from its build report')
    demand(report.get('abiVersion') == pins['frontend']['abiVersion'] == 1 and
           report.get('runtimeIdentity') == pins['frontend']['runtimeIdentity'], 'Frontend host ABI identity mismatch')
    source = package / 'retroarch-frontend-corresponding-source.tar.gz'
    demand(source.is_file() and not source.is_symlink() and source.stat().st_size > 0,
           'Frontend corresponding source archive missing')
    with tarfile.open(source, 'r:gz') as archive:
        prepared = archive.getmember('source/neostation/prepared-source.json')
        demand(prepared.isfile() and prepared.size < 1024 * 1024, 'Invalid prepared frontend source identity')
        recorded = json.load(archive.extractfile(prepared))
        demand(recorded.get('frontendCommit') == pins['frontend']['commit'] and
               recorded.get('sourceIpaSha256') == pins['sourceIpa']['sha256'] and
               recorded.get('adapterAbiVersion') == 1 and recorded.get('standaloneApplicationEntry') is False,
               'Corresponding source archive references a different frontend/host ABI')
    return {
        'schemaVersion': 1,
        'frontendHostCommit': frontend_host_commit,
        'frontendCommit': pins['frontend']['commit'],
        'frontendSha256': sha256(data),
        'frontendABI': pins['frontend']['abiVersion'],
        'runtimeIdentity': pins['frontend']['runtimeIdentity'],
        'sourceIpaSha256': pins['sourceIpa']['sha256'],
        'sourcePinsSha256': file_hash(package / 'source-pins.json'),
        'correspondingSourceSha256': file_hash(source),
        'supplementaryInputs': {core['id']: core['supplementaryInput'] for core in pins['cores']
                                if core.get('supplementaryInput')},
        'coreIds': sorted(by_id),
        'coreBinarySha256': {core['id']: core['sha256'] for core in pins['cores']},
        'files': {name: file_hash(path) for name, path in sorted(files.items())},
        'signatureState': 'frontend unsigned; original core bytes retained; installer must resign nested binaries',
        'deviceValidated': False,
    }


def validate_dependencies(files: dict[str, Path], exists) -> None:
    for relative, source in files.items():
        if relative != FRONTEND_NAME and not relative.endswith('.libretro'):
            continue
        for dependency in macho(source.read_bytes())['dependencies']:
            if dependency.startswith('@rpath/'):
                required = 'Frameworks/' + dependency.removeprefix('@rpath/')
                demand(exists(required), f'Embedded RetroArch dependency missing: {relative} -> {dependency}')


def validate_info(info: dict) -> None:
    demand(info.get('UIFileSharingEnabled') is True, 'NeoStation Documents sharing is disabled')
    demand(info.get('LSSupportsOpeningDocumentsInPlace') is True, 'Editing NeoStation Documents in place is disabled')
    minimum = str(info.get('MinimumOSVersion', '0')).split('.')
    demand(tuple(map(int, (minimum + ['0'])[:2])) >= (18, 0), 'Embedded RetroArch requires an iOS 18+ host')
    demand(bool(info.get('CFBundleIdentifier')) and bool(info.get('CFBundleExecutable')), 'Invalid host app Info.plist')


def _app_conflicts(app: Path, sources: dict[str, Path], identity_data: bytes, pins: dict) -> None:
    # Existing engines may have arbitrary framework names. Only the libretro
    # framework namespace and our own resource directory belong to this step.
    frameworks = app / 'Frameworks'
    expected = {PurePosixPath(core['binary']).parts[1] for core in pins['cores']}
    if frameworks.exists():
        for path in frameworks.rglob('*.libretro.framework'):
            demand(path.parent == frameworks and path.name in expected, f'Uncurated libretro framework in app: {path}')
    desired_resources = {name.removeprefix('RetroArchResources/') for name in sources if name.startswith('RetroArchResources/')}
    if (app / 'RetroArchResources').exists():
        existing = tree_files(app / 'RetroArchResources')
        demand(set(existing) <= desired_resources, 'Existing app contains uncurated RetroArch resources')
    for name, source in sources.items():
        destination = app / name
        demand(not destination.is_symlink(), f'Unsafe app destination: {name}')
        if destination.exists():
            demand(destination.is_file() and file_hash(destination) == file_hash(source), f'Conflicting app-owned RetroArch file: {name}')
        for parent in destination.parents:
            if parent == app:
                break
            demand(not parent.is_symlink(), f'Unsafe app destination directory: {parent}')
    identity = app / 'retroarch-embedded-identity.json'
    if identity.exists():
        demand(not identity.is_symlink() and identity.read_bytes() == identity_data,
               'App already embeds a different RetroArch build identity')


def embed(package: Path, app: Path, frontend_host_commit: str, host_commit: str,
          pins: dict | None = None) -> dict:
    pins = pins or PINS
    identity = validate_package(package, frontend_host_commit, pins)
    demand(app.is_dir() and not app.is_symlink(), 'Expected one built Runner.app directory')
    validate_info(plistlib.loads((app / 'Info.plist').read_bytes()))
    identity['hostCommit'] = host_commit
    identity_data = (json.dumps(identity, indent=2, sort_keys=True) + '\n').encode()
    sources = package_files(package, pins)
    _app_conflicts(app, sources, identity_data, pins)
    validate_dependencies(sources, lambda relative: relative in sources or (app / relative).is_file())
    # Validate all candidates/conflicts first. Stage bytes separately, then move
    # only previously absent files so a failed copy cannot replace another core.
    stage = Path(tempfile.mkdtemp(prefix='retroarch-embed-', dir=app.parent))
    copied = []
    try:
        for relative, source in sources.items():
            staged = stage / relative
            staged.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, staged)
        for relative in sources:
            destination = app / relative
            if destination.exists():
                continue
            destination.parent.mkdir(parents=True, exist_ok=True)
            os.replace(stage / relative, destination)
            copied.append(destination)
        identity_path = app / 'retroarch-embedded-identity.json'
        if not identity_path.exists():
            temporary = stage / 'identity.json'
            temporary.write_bytes(identity_data)
            os.replace(temporary, identity_path)
            copied.append(identity_path)
        validate_app(app, package, frontend_host_commit, host_commit, pins)
    except BaseException:
        for path in reversed(copied):
            path.unlink(missing_ok=True)
        raise
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return identity


def validate_app(app: Path, package: Path, frontend_host_commit: str, host_commit: str,
                 pins: dict | None = None) -> dict:
    pins = pins or PINS
    identity = validate_package(package, frontend_host_commit, pins)
    identity['hostCommit'] = host_commit
    validate_info(plistlib.loads((app / 'Info.plist').read_bytes()))
    demand(read_json(app / 'retroarch-embedded-identity.json') == identity, 'Embedded RetroArch provenance differs from approved package')
    _app_conflicts(app, package_files(package, pins), (json.dumps(identity, indent=2, sort_keys=True) + '\n').encode(), pins)
    validate_dependencies(package_files(package, pins), lambda relative: (app / relative).is_file())
    for relative, expected in identity['files'].items():
        demand(file_hash(app / relative) == expected, f'Embedded file differs from approved package: {relative}')
    demand(not any(path.name == 'RetroArch.app' for path in app.rglob('*.app')), 'Standalone RetroArch application is nested in NeoStation')
    return {'success': True, 'structuralValidation': True, 'deviceValidated': False, **identity}


def validate_ipa(ipa: Path, package: Path, frontend_host_commit: str, host_commit: str,
                 pins: dict | None = None) -> dict:
    pins = pins or PINS
    identity = validate_package(package, frontend_host_commit, pins)
    identity['hostCommit'] = host_commit
    expected_frameworks = {PurePosixPath(core['binary']).parts[1] for core in pins['cores']}
    with zipfile.ZipFile(ipa) as archive:
        entries = archive.infolist()
        names = [entry.filename for entry in entries]
        demand(len(names) == len(set(names)), 'IPA contains duplicate members')
        for entry in entries:
            path = PurePosixPath(entry.filename)
            demand(not path.is_absolute() and '..' not in path.parts and '\\' not in entry.filename
                   and not stat.S_ISLNK(entry.external_attr >> 16), f'Unsafe IPA entry: {entry.filename}')
        apps = {PurePosixPath(name).parts[1] for name in names if len(PurePosixPath(name).parts) > 2
                and PurePosixPath(name).parts[0] == 'Payload' and PurePosixPath(name).parts[1].endswith('.app')}
        demand(len(apps) == 1, 'Expected exactly one top-level NeoStation application')
        prefix = 'Payload/' + next(iter(apps)) + '/'
        demand(not any(part.endswith('.app') for name in names if name.startswith(prefix)
                       for part in PurePosixPath(name[len(prefix):]).parts), 'IPA contains a nested standalone application')
        validate_info(plistlib.loads(archive.read(prefix + 'Info.plist')))
        for name in names:
            if not name.startswith(prefix):
                continue
            parts = PurePosixPath(name[len(prefix):]).parts
            for index, part in enumerate(parts):
                if part.endswith('.libretro.framework'):
                    demand(index == 1 and parts[0] == 'Frameworks' and part in expected_frameworks,
                           f'Uncurated/nested libretro framework in IPA: {name}')
        actual_frameworks = {PurePosixPath(name[len(prefix):]).parts[1] for name in names if name.startswith(prefix + 'Frameworks/')
                             and len(PurePosixPath(name[len(prefix):]).parts) >= 3
                             and PurePosixPath(name[len(prefix):]).parts[1].endswith('.libretro.framework')}
        demand(actual_frameworks == expected_frameworks, 'IPA contains missing or uncurated libretro core frameworks')
        validate_dependencies(package_files(package, pins), lambda relative: prefix + relative in names)
        for relative, expected in identity['files'].items():
            demand(sha256(archive.read(prefix + relative)) == expected, f'IPA embedded file identity mismatch: {relative}')
        demand(json.loads(archive.read(prefix + 'retroarch-embedded-identity.json')) == identity,
               'IPA RetroArch provenance differs from approved build')
        resources = {name[len(prefix):] for name in names if name.startswith(prefix + 'RetroArchResources/') and not name.endswith('/')}
        demand(resources == {name for name in identity['files'] if name.startswith('RetroArchResources/')},
               'IPA includes missing or uncurated RetroArch resource files')
        demand(archive.testzip() is None, 'IPA CRC validation failed')
    return {'success': True, 'structuralValidation': True, 'deviceValidated': False,
            'ipaSha256': file_hash(ipa), 'ipaBytes': ipa.stat().st_size, **identity}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['embed', 'verify-app', 'verify-ipa'])
    parser.add_argument('--package', type=Path, required=True)
    parser.add_argument('--frontend-host-commit', required=True)
    parser.add_argument('--host-commit', required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--ipa', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    if args.command in {'embed', 'verify-app'} and args.app is None:
        parser.error('--app is required')
    if args.command == 'verify-ipa' and args.ipa is None:
        parser.error('--ipa is required')
    if args.command == 'embed':
        result = embed(args.package, args.app, args.frontend_host_commit, args.host_commit)
    elif args.command == 'verify-app':
        result = validate_app(args.app, args.package, args.frontend_host_commit, args.host_commit)
    else:
        result = validate_ipa(args.ipa, args.package, args.frontend_host_commit, args.host_commit)
    text = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(text)
    print(text, end='')


if __name__ == '__main__':
    main()
