#!/usr/bin/env python3
"""Validate the packaged NeoStation IPA and the embedded RPCS3 runtime contract.

This runs after the unsigned Xcode build, RPCS3 dylib injection, and ad-hoc host
entitlement embedding. It deliberately validates the final ZIP rather than the
intermediate .app so the uploaded artifact is exactly what was checked.
"""
from __future__ import annotations

import argparse
import json
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
from validate_rpcs3_embedded_core import (
    FORBIDDEN_UNDEFINED_SYMBOLS,
    validate_core,
)

ROOT = Path(__file__).resolve().parents[1]
CORE_NAME = 'libRPCS3Core.dylib'
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


class ValidationError(RuntimeError):
    pass


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise ValidationError(message)


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
        validate_core(core.read_bytes())

        symbols = command_output('nm', '-g', str(core))
        missing_symbols = [symbol for symbol in REQUIRED_CORE_SYMBOLS if f' {symbol}' not in symbols]
        demand(not missing_symbols,
               'Packaged RPCS3 core is missing exports: ' + ', '.join(missing_symbols))

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
            'rpcS3RequiredSymbols': list(REQUIRED_CORE_SYMBOLS),
            'rpcS3ForbiddenLoadTimeImports': list(FORBIDDEN_UNDEFINED_SYMBOLS),
            'rpcS3LoadTimeImportsValidated': True,
            'runtimeEntitlements': {
                key: entitlements.get(key) for key in REQUIRED_RUNTIME_ENTITLEMENTS
            },
            'jitHelperBundleIdentifiers': helper_identifiers,
            'embeddedPacketTunnelPresent': False,
            'networkExtensionEntitlementPresent': False,
            'lazyLoadValidated': True,
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
