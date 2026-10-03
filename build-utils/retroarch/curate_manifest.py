#!/usr/bin/env python3
"""Audit the pinned donor IPA against its exact App Store allowlist and local systems.

This emits candidate pins for review; it never updates source.json or advertises
unqualified cores. Hardware cores are reported separately from software cores.
"""
from collections import Counter
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import subprocess
import zipfile

from package_ipa import macho, safe_name

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_PINS = Path(__file__).with_name('source.json')
EXCLUDED_SYSTEMS = {'gc', 'wii', 'wiiu', 'switch'}
EXCLUDED_CORES = {'dolphin'}
# Upstream C64 database compatibility does not establish the machine mode
# required to launch a plain C64 game in these distinct-machine variants.
# Explicit future C128/SuperCPU library declarations remain eligible.
NO_DATABASE_INFERENCE = {'vice_x128', 'vice_xscpu64'}
NAMED_UNSTABLE = re.compile(r'(?i)(?:^|[\W_])(?:beta|experimental|test)(?:$|[\W_])')
# These exact upstream database names identify the corresponding existing
# NeoStation libraries. Their source assets and extension overlap are recorded
# in every supplemental mapping. No folders are invented from a core filename.
DATABASE_SYSTEMS = {
    'Nintendo - Super Nintendo Entertainment System': {'snes', 'sfc', 'snes-hacks', 'sfc-hacks'},
    'Nintendo - Satellaview': {'satellaview'},
    'Nintendo - Nintendo Entertainment System': {'nes', 'fc', 'nes-hacks'},
    'Nintendo - Family Computer Disk System': {'fds'},
    'Nintendo - Game Boy': {'gb', 'gb-hacks'},
    'Nintendo - Game Boy Color': {'gbc', 'gbc-hacks'},
    'Nintendo - Game Boy Advance': {'gba', 'gba-hacks'},
    'Nintendo - Nintendo DS': {'ds'},
    'Nintendo - Nintendo 3DS': {'3ds'},
    'Sega - Mega Drive - Genesis': {'md', 'genesis', 'md-hacks', 'gen-hacks'},
    'Sega - Mega-CD - Sega CD': {'mcd', 'scd'},
    'Sega - Game Gear': {'gg', 'gg-hacks'},
    'Sega - Master System - Mark III': {'sms', 'mark3'},
    'Sega - SG-1000': {'sg1k'},
    'Sega - PICO': {'pico'},
    'Sega - Saturn': {'sat'},
    'Coleco - ColecoVision': {'cv'},
    'Emerson - Arcadia 2001': {'a2001'},
    'Interton - VC 4000': {'vc4k'},
    'NEC - PC Engine - TurboGrafx 16': {'pce', 'tg16'},
    'NEC - PC Engine SuperGrafx': {'pce', 'tg16'},
    'NEC - PC Engine CD - TurboGrafx-CD': {'pccd', 'tgcd'},
    'Atari - Lynx': {'lynx'},
    'Atari - 2600': {'2600'},
    'Atari - 5200': {'5200'},
    'Atari - 7800': {'7800'},
    'Atari - Jaguar': {'jag'},
    'Commodore - 64': {'c64'},
    'Sony - PlayStation Portable': {'psp', 'pspminis'},
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse_info(data):
    """Include unquoted integers such as firmware_count, unlike string-only parsing."""
    text = data.decode('utf-8')
    return {
        match[1]: match[2] if match[2] is not None else match[3]
        for match in re.finditer(r'^\s*(\w+)\s*=\s*(?:"([^"\r\n]*)"|([^\s#]+))', text, re.M)
    }


def appstore_ids(text):
    match = re.search(r'^appstore_cores=\(\s*(.*?)^\)', text, re.M | re.S)
    if not match:
        raise ValueError('Pinned upstream App Store allowlist missing')
    tokens = [line.split('#', 1)[0].strip() for line in match[1].splitlines()]
    ids = {token for token in tokens if token}
    if not ids or any(not re.fullmatch(r'[A-Za-z0-9_-]+', token) for token in ids):
        raise ValueError('Unexpected App Store allowlist syntax')
    return ids


def system_index(folder):
    records = {}
    declarations = {}
    asset_digests = {}
    for asset in sorted(folder.glob('*.json')):
        raw = asset.read_bytes()
        document = json.loads(raw)
        system = document['system']
        identifier = system['id']
        if not isinstance(identifier, str) or identifier in records:
            raise ValueError(f'Invalid or duplicate system identifier: {asset}')
        if not isinstance(system.get('folders'), list) or not system['folders']:
            raise ValueError(f'System has no declared folders: {asset}')
        records[identifier] = {
            'asset': 'assets/systems/' + asset.name,
            'name': system['name'],
            'folders': system['folders'],
            'extensions': system.get('extensions', []),
            'type': system.get('details', {}).get('type'),
        }
        asset_digests[asset.name] = digest(raw)
        for emulator in document.get('emulators', []):
            references = {}
            unique_id = emulator.get('unique_id', '')
            match = re.search(r'\.ra(?:32|64)?\.([^\s.]+)$', unique_id)
            if match:
                references[match[1]] = {'uniqueId': unique_id}
            for platform, fields in emulator.get('platforms', {}).items():
                for key, value in fields.items():
                    if not isinstance(value, str):
                        continue
                    # Current assets have no core_filename field. Older schema
                    # values and exact desktop -L/Android LIBRETRO paths are
                    # accepted only when they contain an explicit core ID.
                    matches = re.findall(r'([A-Za-z0-9_-]+)_libretro\.(?:dll|dylib|so)\b', value)
                    if key == 'core_filename':
                        stem = value.removesuffix('_libretro')
                        if re.fullmatch(r'[A-Za-z0-9_-]+', stem):
                            matches.append(stem)
                    matches += re.findall(r'--es\s+LIBRETRO\s+"([A-Za-z0-9_-]+)"', value)
                    for core in matches:
                        references.setdefault(core, {'platform': platform, 'field': key, 'value': value})
            for core, reference in references.items():
                evidence = {'systemId': identifier, 'asset': records[identifier]['asset'],
                            'source': 'declared-emulator', 'reference': reference,
                            'defaultCore': emulator.get('default_core') is True}
                declarations.setdefault(core, []).append(evidence)
    systems_digest = digest(json.dumps(asset_digests, sort_keys=True, separators=(',', ':')).encode())
    return records, declarations, asset_digests, systems_digest


def map_systems(core, info, records, declarations):
    evidence = list(declarations.get(core, []))
    present = {entry['systemId'] for entry in evidence}
    core_extensions = set(info.get('supported_extensions', '').split('|')) - {'', '/', 'zip', '7z', 'gz'}
    databases = [] if core in NO_DATABASE_INFERENCE else info.get('database', '').split('|')
    for database in databases:
        for identifier in sorted(DATABASE_SYSTEMS.get(database, set())):
            if identifier not in records or identifier in present:
                continue
            overlap = core_extensions & set(records[identifier]['extensions'])
            if not overlap:
                continue
            evidence.append({'systemId': identifier, 'asset': records[identifier]['asset'],
                             'source': 'exact-upstream-database', 'database': database,
                             'matchingExtensions': sorted(overlap)})
            present.add(identifier)
    return sorted(present - EXCLUDED_SYSTEMS), evidence


def classify(core, info, binary_present, info_present, systems):
    reasons = []
    if core in EXCLUDED_CORES or set(systems) & EXCLUDED_SYSTEMS:
        reasons.append('excluded-platform-policy')
    if not info_present:
        reasons.append('missing-info')
    if not binary_present:
        reasons.append('missing-binary')
    name = ' '.join([core, info.get('display_name', ''), info.get('corename', '')])
    if info.get('is_experimental', 'false').lower() == 'true' or NAMED_UNSTABLE.search(name):
        reasons.append('experimental-or-named-beta-test')
    if reasons:
        return 'excluded', reasons
    if info.get('hw_render', 'false').lower() == 'true' or info.get('required_hw_api'):
        required = info.get('required_hw_api', '')
        if re.search(r'OpenGL ES\s*>=\s*[23]\.', required):
            return 'hardware-candidate', ['requires-opengles-and-no-jit-runtime-review']
        if required:
            return 'gpu-incompatible', ['requires-desktop-gl-or-vulkan-driver']
        return 'hardware-unqualified', ['hardware-api-not-declared']
    if not systems:
        return 'unmapped', ['no-existing-system-mapping']
    return 'software-candidate', ['requires-device-validation']


def firmware_entries(info):
    try:
        count = int(info.get('firmware_count', '0'))
    except ValueError as error:
        raise ValueError('Invalid firmware_count') from error
    if count < 0 or count > 1024:
        raise ValueError('Invalid firmware_count range')
    entries = []
    for index in range(count):
        path = info.get(f'firmware{index}_path')
        if not path:
            raise ValueError(f'Missing firmware{index}_path')
        if PurePosixPath(path).is_absolute() or '..' in PurePosixPath(path).parts:
            raise ValueError('Unsafe firmware path')
        entries.append({'path': path, 'description': info.get(f'firmware{index}_desc', path),
                        'optional': info.get(f'firmware{index}_opt', 'false').lower() == 'true'})
    return entries


def audit(ipa, upstream, systems_folder, pins_path=DEFAULT_PINS):
    pins = json.loads(pins_path.read_text())
    actual = subprocess.check_output(['git', '-C', str(upstream), 'rev-parse', 'HEAD'], text=True).strip()
    if actual != pins['frontend']['commit']:
        raise ValueError(f'Frontend source mismatch: {actual}')
    dirty = subprocess.check_output(['git', '-C', str(upstream), 'status', '--porcelain', '--untracked-files=no'], text=True)
    if dirty.strip():
        raise ValueError('Pinned upstream checkout has modified tracked files')
    with ipa.open('rb') as stream:
        actual_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
    if actual_hash != pins['sourceIpa']['sha256'] or ipa.stat().st_size != pins['sourceIpa']['bytes']:
        raise ValueError(f'Donor IPA hash/length mismatch: {actual_hash}')
    allowlist_file = upstream / 'pkg/apple/update-cores.sh'
    allowlist_data = allowlist_file.read_bytes()
    allowed = appstore_ids(allowlist_data.decode())
    records, declarations, asset_digests, systems_digest = system_index(systems_folder)
    candidates = []
    with zipfile.ZipFile(ipa) as archive:
        names = set(archive.namelist())
        for entry in archive.infolist():
            safe_name(entry)
        prefix = 'Payload/RetroArch.app/'
        metadata = plistlib.loads(archive.read(prefix + 'Info.plist'))
        if metadata.get('CFBundleVersion') != pins['sourceIpa']['bundleVersion']:
            raise ValueError('Donor IPA version mismatch')
        with zipfile.ZipFile(io.BytesIO(archive.read(prefix + 'assets.zip'))) as assets:
            asset_names = set(assets.namelist())
            for core in sorted(allowed):
                stem = core.replace('_', '.') + '.libretro'
                binary = 'Frameworks/' + stem + '.framework/' + stem
                info_path = 'info/' + core + '_libretro.info'
                info_data = assets.read(info_path) if info_path in asset_names else None
                info = parse_info(info_data) if info_data is not None else {}
                system_ids, evidence = map_systems(core, info, records, declarations)
                present = prefix + binary in names
                state, reasons = classify(core, info, present, info_data is not None, system_ids)
                entry = {
                    'id': core, 'title': info.get('corename') or info.get('display_name') or core,
                    'displayName': info.get('display_name', core), 'binary': binary,
                    'missingBinary': not present, 'info': info_path,
                    'infoSha256': digest(info_data) if info_data is not None else None,
                    'systemIds': system_ids, 'mappingEvidence': evidence,
                    'status': state, 'reasons': reasons,
                    'isExperimentalDeclared': info.get('is_experimental'),
                    'hardwareRenderingDeclared': info.get('hw_render'),
                    'requiredHardwareAPI': info.get('required_hw_api'),
                    'license': info.get('license', ''), 'permissions': info.get('permissions', ''),
                    'supportedExtensions': [item for item in info.get('supported_extensions', '').split('|') if item],
                    'savestate': info.get('savestate', '').lower() == 'true',
                    'cheats': info.get('cheats', '').lower() == 'true',
                    'firmware': firmware_entries(info),
                }
                if present:
                    plist_path = prefix + str(PurePosixPath(binary).parent) + '/Info.plist'
                    framework_plist = plistlib.loads(archive.read(plist_path))
                    if framework_plist.get('CFBundleExecutable') != stem:
                        raise ValueError(f'Framework executable mismatch: {core}')
                    data = archive.read(prefix + binary)
                    entry['sha256'] = digest(data)
                    try:
                        entry['macho'] = macho(data)
                    except ValueError as error:
                        entry['status'] = 'excluded'
                        entry['reasons'].append('binary-platform-or-dependency-invalid')
                        entry['binaryValidationError'] = str(error)
                candidates.append(entry)
        supplied = {PurePosixPath(name).parent.name.removesuffix('.libretro.framework').replace('.', '_')
                    for name in names if re.fullmatch(r'Payload/RetroArch\.app/Frameworks/[^/]+\.libretro\.framework/Info\.plist', name)}
    counts = Counter(entry['status'] for entry in candidates)
    software = [entry for entry in candidates if entry['status'] == 'software-candidate']
    fields = ['id', 'binary', 'systemIds', 'sha256', 'infoSha256', 'info', 'title',
              'license', 'savestate', 'cheats', 'supportedExtensions', 'firmware']
    core_pins = [{key: entry[key] for key in fields} for entry in software]
    return {
        'schemaVersion': 1, 'sourceIpa': pins['sourceIpa'], 'frontend': pins['frontend'],
        'allowlist': {'frontendCommit': actual, 'path': 'pkg/apple/update-cores.sh',
                      'sha256': digest(allowlist_data), 'coreIds': sorted(allowed)},
        'systemAssets': {'count': len(records), 'combinedSha256': systems_digest,
                         'sha256ByFilename': asset_digests},
        'policy': {'excludedSystemIds': sorted(EXCLUDED_SYSTEMS),
                   'excludedCoreIds': sorted(EXCLUDED_CORES),
                   'noDatabaseInferenceCoreIds': sorted(NO_DATABASE_INFERENCE),
                   'hardwareDriver': 'gl; OpenGL ES 2/3 must be explicitly qualified',
                   'jitEnabled': False, 'availabilityIsDeviceQualification': False},
        'counts': {'appStoreAllowlisted': len(allowed),
                   'allowlistedPresentBinary': sum(not entry['missingBinary'] for entry in candidates),
                   'suppliedLibretroFrameworks': len(supplied), **dict(sorted(counts.items()))},
        'nonAppStoreSuppliedCoreIds': sorted(supplied - allowed),
        'candidates': candidates,
        'softwareCandidatePins': core_pins,
        'softwareCandidateSystems': sorted({system for entry in software for system in entry['systemIds']}),
        'warning': 'App Store allowlisting and matching binaries do not prove stability inside NeoStation. '
                   'Hardware, input and no-JIT runtime qualification remains required before offering each core.',
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--upstream', type=Path, required=True)
    parser.add_argument('--systems', type=Path, default=ROOT / 'assets/systems')
    parser.add_argument('--pins', type=Path, default=DEFAULT_PINS)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.ipa.resolve(), args.upstream.resolve(), args.systems.resolve(), args.pins.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'counts': report['counts'], 'softwareCandidateSystems': report['softwareCandidateSystems'],
                      'output': str(args.output)}, ensure_ascii=False))


if __name__ == '__main__':
    main()
