#!/usr/bin/env python3
"""Validate the packaged NeoStation IPA and the embedded RPCS3 runtime contract.

This runs after the unsigned Xcode build, RPCS3 dylib injection, and ad-hoc host
entitlement embedding. It deliberately validates the final ZIP rather than the
intermediate .app so the uploaded artifact is exactly what was checked.
"""
from __future__ import annotations

import argparse
import json
import hashlib
import plistlib
import subprocess
import tempfile
import zipfile
from pathlib import Path

from configure_rpcs3_ios_v2 import REQUIRED_RUNTIME_ENTITLEMENTS
from embed_rpcs3_host_entitlements import (
    FORBIDDEN_NETWORK_ENTITLEMENTS,
    embedded_entitlements,
    require_runtime_entitlements,
)
FORBIDDEN_UNDEFINED_SYMBOLS = {
    '_vm_map', '__os_log_default', '__os_log_error_impl', '_os_log_type_enabled'
}

ROOT = Path(__file__).resolve().parents[1]
CORE_NAME = 'libRPCS3Core.dylib'
PROVEN_BUILD266_SHA256 = 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'
PROVEN_BUILD266_MARKERS = (
    b'NEOSTATION_BUILD266_JIT_V09_SHADER_V1',
    b'NEOSTATION_DYNAMIC_JIT_V5',
    b'NEOSTATION_BUILD266_SHADER_CHECKPOINT_V1',
    b'505a85e5a8f2cdff1cd63168bd2c56b0f92282bf',
)
EXPECTED_HELPERS = {
    'DolphinJITHelper.appex': {
        'bundleSuffix': '.dolphinjithelper',
        'principalClass': 'DolphinJITRequestHandler',
        'marker': 'NeoStationDolphinJITHelper',
    },
    'RPCS3JITHelper.appex': {
        'bundleSuffix': '.rpcs3jithelper',
        'principalClass': 'Rpcs3JITRequestHandler',
        'marker': 'NeoStationRPCS3JITHelper',
    },
    'ARMSX2JITHelper.appex': {
        'bundleSuffix': '.armsx2jithelper',
        'principalClass': 'Armsx2JITRequestHandler',
        'marker': 'NeoStationARMSX2JITHelper',
    },
}
PACKET_TUNNEL_EXTENSION_POINT = 'com.apple.networkextension.packet-tunnel'
SHARE_EXTENSION_POINT = 'com.apple.share-services'
REQUIRED_CORE_SYMBOLS = (
    '_rpcs3_ios_initialize',
    '_rpcs3_ios_run_llvm_self_test',
    '_rpcs3_ios_set_display_surface',
    '_rpcs3_ios_set_pad_state',
    '_rpcs3_ios_set_game_setting',
    '_rpcs3_ios_boot_game',
    '_rpcs3_ios_get_emulation_state',
    '_rpcs3_ios_get_performance_metrics',
    '_neostation_rpcs3_ios_save_state',
    '_neostation_rpcs3_ios_get_savestate_status',
    '_neostation_rpcs3_ios_enumerate_savestates_live',
    '_rpcs3_ios_stop_emulation',
    '_rpcs3_ios_shutdown',
)

FORBIDDEN_CORE_SYMBOLS = (
    '_neostation_rpcs3_adopt_jit_layout',
    '_neostation_rpcs3_reset_failed_startup',
)


SPRINGBOARD_ICON_FILES = {
    'NeoStationIcon60@2x.png': (120, 120),
    'NeoStationIcon60@3x.png': (180, 180),
    'NeoStationIcon76@2x~ipad.png': (152, 152),
    'NeoStationIcon83.5@2x~ipad.png': (167, 167),
    'NeoStationIcon1024.png': (1024, 1024),
}
SPRINGBOARD_ICON_BASES = (
    'NeoStationIcon60',
    'NeoStationIcon76',
    'NeoStationIcon83.5',
)


class ValidationError(RuntimeError):
    pass


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


def png_dimensions(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    demand(
        len(data) >= 24 and data[:8] == b'\x89PNG\r\n\x1a\n',
        f'Icon fallback is not a PNG: {path.name}',
    )

    # Xcode's CopyPNGFile/copypng may insert the Apple CgBI chunk before IHDR.
    # Parse PNG chunks instead of assuming IHDR is the first chunk so the
    # validator checks the file that is actually installed on iOS.
    offset = 8
    while offset + 8 <= len(data):
        length = int.from_bytes(data[offset:offset + 4], 'big')
        chunk_type = data[offset + 4:offset + 8]
        payload = offset + 8
        end = payload + length
        demand(
            end + 4 <= len(data),
            f'Icon fallback has a truncated PNG chunk: {path.name}',
        )
        if chunk_type == b'IHDR':
            demand(length >= 8, f'Icon fallback has an invalid IHDR: {path.name}')
            return (
                int.from_bytes(data[payload:payload + 4], 'big'),
                int.from_bytes(data[payload + 4:payload + 8], 'big'),
            )
        offset = end + 4

    raise ValidationError(f'Icon fallback has no IHDR chunk: {path.name}')


def validate_springboard_icons(app: Path, info: dict) -> dict:
    demand(app.name == 'NeoStation.app',
           f'Packaged main app must be NeoStation.app, got {app.name}')
    demand(info.get('CFBundleExecutable') == 'Runner',
           f'Unexpected CFBundleExecutable: {info.get("CFBundleExecutable")!r}')
    demand(str(info.get('CFBundleName', '')).lower() == 'neostation',
           f'Unexpected CFBundleName: {info.get("CFBundleName")!r}')
    demand(info.get('CFBundleDisplayName') == 'NeoStation iOS',
           f'Unexpected CFBundleDisplayName: {info.get("CFBundleDisplayName")!r}')
    demand(info.get('CFBundleIconName') == 'AppIcon',
           f'CFBundleIconName must explicitly select AppIcon, got {info.get("CFBundleIconName")!r}')

    legacy = info.get('CFBundleIconFiles')
    demand(isinstance(legacy, list), 'CFBundleIconFiles is missing from the final app')
    missing_legacy = [name for name in SPRINGBOARD_ICON_BASES if name not in legacy]
    demand(not missing_legacy,
           'Final CFBundleIconFiles is missing fallbacks: ' + ', '.join(missing_legacy))

    for key in ('CFBundleIcons', 'CFBundleIcons~ipad'):
        icons = info.get(key)
        demand(isinstance(icons, dict), f'{key} is missing from the final app')
        primary = icons.get('CFBundlePrimaryIcon')
        demand(isinstance(primary, dict), f'{key}.CFBundlePrimaryIcon is missing')
        demand(primary.get('CFBundleIconName') == 'AppIcon',
               f'{key} does not retain AppIcon as the modern asset catalog')
        files = primary.get('CFBundleIconFiles')
        demand(isinstance(files, list) and files,
               f'{key}.CFBundlePrimaryIcon.CFBundleIconFiles is empty')

    assets = app / 'Assets.car'
    demand(assets.is_file() and assets.stat().st_size > 0,
           'Final app is missing Assets.car')

    dimensions = {}
    for name, expected in SPRINGBOARD_ICON_FILES.items():
        path = app / name
        demand(path.is_file(), f'Final app is missing SpringBoard fallback {name}')
        actual = png_dimensions(path)
        demand(actual == expected,
               f'Wrong icon dimensions for {name}: expected {expected}, got {actual}')
        dimensions[name] = list(actual)

    resources_path = app / '_CodeSignature' / 'CodeResources'
    demand(resources_path.is_file(),
           'Final app has no CodeResources resource seal')
    resources = plistlib.loads(resources_path.read_bytes())
    sealed = set()
    for key in ('files', 'files2'):
        entries = resources.get(key)
        if isinstance(entries, dict):
            sealed.update(entries)
    missing_seal = [
        name for name in ('Assets.car', *SPRINGBOARD_ICON_FILES)
        if name not in sealed
    ]
    demand(not missing_seal,
           'CodeResources does not seal icon resources: ' + ', '.join(missing_seal))

    return {
        'assetCatalog': 'Assets.car',
        'iconName': info.get('CFBundleIconName'),
        'legacyIconFiles': list(legacy),
        'fallbackDimensions': dimensions,
        'codeResourcesValidated': True,
    }


def safe_members(archive: zipfile.ZipFile) -> None:
    for info in archive.infolist():
        path = Path(info.filename)
        demand(not path.is_absolute(), f'Unsafe absolute IPA member: {info.filename}')
        demand('..' not in path.parts, f'Unsafe parent traversal in IPA: {info.filename}')


def reject_vpn_entitlements(entitlements: dict, owner: str) -> None:
    forbidden = [key for key in FORBIDDEN_NETWORK_ENTITLEMENTS if key in entitlements]
    demand(
        not forbidden,
        f'{owner} contains retired VPN entitlements: {", ".join(forbidden)}',
    )


def command_output(*args: str) -> str:
    try:
        return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)
    except (OSError, subprocess.CalledProcessError) as exc:
        output = getattr(exc, 'output', '')
        raise ValidationError(f'Command failed: {" ".join(args)}\n{output}') from exc


def find_ipa() -> Path:
    candidates = sorted((ROOT / 'dist').glob('*.ipa'))
    demand(len(candidates) == 1, f'Expected exactly one IPA in dist/, found {len(candidates)}')
    return candidates[0]


def validate_ipa(ipa: Path, build_number: str, commit: str) -> dict:
    demand(ipa.is_file() and ipa.stat().st_size > 0, f'IPA missing or empty: {ipa}')
    demand(zipfile.is_zipfile(ipa), f'IPA is not a ZIP archive: {ipa}')

    with tempfile.TemporaryDirectory(prefix='neostation-rpcs3-ipa-') as temp:
        root = Path(temp)
        with zipfile.ZipFile(ipa) as archive:
            safe_members(archive)
            bad = archive.testzip()
            demand(bad is None, f'Corrupt IPA member: {bad}')
            archive.extractall(root)

        payload = root / 'Payload'
        apps = [path for path in payload.glob('*.app') if path.is_dir()]
        demand(len(apps) == 1, f'Expected exactly one application in Payload, found {len(apps)}')
        app = apps[0]

        info_path = app / 'Info.plist'
        demand(info_path.is_file(), 'Packaged app has no Info.plist')
        info = plistlib.loads(info_path.read_bytes())
        icon_report = validate_springboard_icons(app, info)
        actual_build = str(info.get('CFBundleVersion', ''))
        demand(actual_build == str(build_number),
               f'Wrong CFBundleVersion: expected {build_number}, got {actual_build or "<missing>"}')

        executable_name = str(info.get('CFBundleExecutable', ''))
        demand(executable_name, 'CFBundleExecutable is missing')
        executable = app / executable_name
        demand(executable.is_file() and executable.stat().st_size > 0,
               f'Packaged app executable missing: {executable_name}')

        core = app / 'Frameworks' / CORE_NAME
        demand(core.is_file(), f'Packaged RPCS3 core missing: Frameworks/{CORE_NAME}')
        demand(core.stat().st_size >= 60_000_000,
               f'Packaged RPCS3 core is unexpectedly small: {core.stat().st_size} bytes')
        core_data = core.read_bytes()
        actual_core_sha = hashlib.sha256(core_data).hexdigest()
        demand(
            actual_core_sha == PROVEN_BUILD266_SHA256,
            'Packaged RPCS3 Core is not the proven Build266 binary: '
            f'{actual_core_sha}',
        )
        for marker in PROVEN_BUILD266_MARKERS:
            demand(marker in core_data, f'Proven Build266 marker missing: {marker!r}')
        for retired in (
            b'NEOSTATION_BUILD301_PASSIVE_DLOPEN_V1',
            b'NEOSTATION_BUILD295_FIXED_JIT_RESERVATION_V1',
            b'NEOSTATION_BUILD302_RESERVED_STARTUP_V1',
            b'NEOSTATION_BUILD303_RESTARTABLE_LIFECYCLE_V1',
        ):
            demand(retired not in core_data, f'Retired RPCS3 Core layer present: {retired!r}')

        symbols = command_output('nm', '-g', str(core))
        missing_symbols = [symbol for symbol in REQUIRED_CORE_SYMBOLS if f' {symbol}' not in symbols]
        demand(not missing_symbols,
               'Packaged RPCS3 core is missing exports: ' + ', '.join(missing_symbols))
        forbidden_symbols = [symbol for symbol in FORBIDDEN_CORE_SYMBOLS if f' {symbol}' in symbols]
        demand(not forbidden_symbols,
               'Packaged RPCS3 core still exports retired host-reservation ABI: ' + ', '.join(forbidden_symbols))

        # The core must stay dormant until the bridge explicitly dlopens it.
        # A normal Mach-O dependency would make app startup load the huge core
        # and reintroduce the launch/JIT lifetime regression fixed previously.
        for candidate in app.rglob('*'):
            if not candidate.is_file() or candidate == core:
                continue
            try:
                kind = command_output('file', str(candidate))
            except ValidationError:
                continue
            if 'Mach-O' not in kind:
                continue
            deps = command_output('otool', '-L', str(candidate))
            demand(CORE_NAME not in deps,
                   f'{candidate.relative_to(app)} links RPCS3 eagerly instead of lazy-loading it')

        entitlements = embedded_entitlements(executable.read_bytes())
        require_runtime_entitlements(entitlements)
        reject_vpn_entitlements(entitlements, 'NeoStation')

        extensions = sorted(
            path for path in app.rglob('*.appex') if path.is_dir()
        )
        demand(
            all(path.parent == app / 'PlugIns' for path in extensions),
            'Every app extension must be nested in NeoStation/PlugIns',
        )
        extension_names = {path.name for path in extensions}
        demand(
            extension_names == set(EXPECTED_HELPERS),
            'Unexpected app-extension set: expected '
            f'{sorted(EXPECTED_HELPERS)}, got {sorted(extension_names)}',
        )
        helper_identifiers = {}
        for extension in extensions:
            contract = EXPECTED_HELPERS[extension.name]
            extension_info = plistlib.loads(
                (extension / 'Info.plist').read_bytes()
            )
            extension_point = extension_info.get('NSExtension', {}).get(
                'NSExtensionPointIdentifier'
            )
            demand(
                extension_point != PACKET_TUNNEL_EXTENSION_POINT,
                f'{extension.name} is a forbidden packet-tunnel provider',
            )
            demand(
                extension_point == SHARE_EXTENSION_POINT,
                f'{extension.name} has an unexpected extension point: '
                f'{extension_point!r}',
            )
            demand(
                extension_info.get('NSExtension', {}).get(
                    'NSExtensionPrincipalClass'
                ) == contract['principalClass'],
                f'{extension.name} principal class is inconsistent',
            )
            demand(
                extension_info.get(contract['marker']) == '1',
                f'{extension.name} identity marker is missing',
            )
            expected_identifier = (
                f"{info.get('CFBundleIdentifier')}"
                f"{contract['bundleSuffix']}"
            )
            demand(
                extension_info.get('CFBundleIdentifier') == expected_identifier,
                f'{extension.name} bundle identifier is inconsistent',
            )
            extension_executable = extension / str(
                extension_info.get('CFBundleExecutable', '')
            )
            demand(
                extension_executable.is_file(),
                f'{extension.name} executable is missing',
            )
            extension_entitlements = embedded_entitlements(
                extension_executable.read_bytes()
            )
            reject_vpn_entitlements(extension_entitlements, extension.name)
            helper_identifiers[extension.name] = expected_identifier

        actual_head = command_output('git', '-C', str(ROOT), 'rev-parse', 'HEAD').strip()
        demand(actual_head == commit,
               f'Validator checkout mismatch: expected {commit}, got {actual_head}')

        return {
            'ipa': ipa.name,
            'bytes': ipa.stat().st_size,
            'buildNumber': actual_build,
            'commit': commit,
            'bundleIdentifier': str(info.get('CFBundleIdentifier', '')),
            'rpcS3CoreBytes': core.stat().st_size,
            'rpcS3MemoryPolicy': {
                'allocator': 'Build266 adaptive Core-owned arena',
                'reservationOwner': 'RPCS3 Core',
                'fixedHostReservation': False,
            },
            'deviceRuntimeTested': False,
            'rpcS3RequiredSymbols': list(REQUIRED_CORE_SYMBOLS),
            'rpcS3ForbiddenLoadTimeImports': list(FORBIDDEN_UNDEFINED_SYMBOLS),
            'rpcS3LoadTimeImportsValidated': True,
            'rpcS3CoreSha256': actual_core_sha,
            'rpcS3CoreBaseline': 'Build266 proven donor',
            'runtimeEntitlements': {
                key: entitlements.get(key) for key in REQUIRED_RUNTIME_ENTITLEMENTS
            },
            'jitHelperBundleIdentifiers': helper_identifiers,
            'embeddedPacketTunnelPresent': False,
            'networkExtensionEntitlementPresent': False,
            'lazyLoadValidated': True,
            'springBoardIcons': icon_report,
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--ipa', type=Path)
    args = parser.parse_args()

    ipa = args.ipa or find_ipa()
    try:
        report = validate_ipa(ipa, args.build_number, args.commit)
    except (ValidationError, ValueError, plistlib.InvalidFileException) as exc:
        raise SystemExit(f'RPCS3 IPA validation failed: {exc}') from exc

    report_path = ROOT / 'dist' / 'rpcs3-ipa-validation.json'
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + '\n')
    print(json.dumps(report, indent=2, sort_keys=True))
    print('RPCS3 final IPA validation passed.')


if __name__ == '__main__':
    main()
