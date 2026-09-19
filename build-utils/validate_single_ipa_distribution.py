#!/usr/bin/env python3
"""Validate the LocalDevVPN-only NeoStation IPA distribution contract.

NeoStation ships as one application with its Dolphin and RPCS3 JIT helpers.
The RemotePairing route is supplied by the separately installed LocalDevVPN;
the IPA must not contain a packet-tunnel extension or VPN entitlement.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import tempfile
import zipfile
from pathlib import Path

from embed_rpcs3_host_entitlements import (
    FORBIDDEN_NETWORK_ENTITLEMENTS,
    embedded_entitlements,
    require_runtime_entitlements,
)


EXPECTED_EXTENSIONS = {
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
MACHO_MAGICS = {
    b'\xcf\xfa\xed\xfe',
    b'\xca\xfe\xba\xbe',
    b'\xca\xfe\xba\xbf',
}


class DistributionError(RuntimeError):
    pass


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise DistributionError(message)


def load_plist(path: Path) -> dict:
    payload = plistlib.loads(path.read_bytes())
    demand(isinstance(payload, dict), f'Invalid property list: {path}')
    return payload


def executable_entitlements(path: Path) -> dict:
    demand(path.is_file(), f'Executable is missing: {path}')
    data = path.read_bytes()
    demand(data[:4] in MACHO_MAGICS, f'Expected a Mach-O executable: {path}')
    return embedded_entitlements(data)


def reject_vpn_entitlements(entitlements: dict, owner: str) -> None:
    present = [key for key in FORBIDDEN_NETWORK_ENTITLEMENTS if key in entitlements]
    demand(
        not present,
        f'{owner} contains retired VPN entitlements: {", ".join(present)}',
    )


def validate(ipa: Path) -> dict:
    demand(ipa.is_file() and zipfile.is_zipfile(ipa), f'Invalid IPA: {ipa}')
    with tempfile.TemporaryDirectory(prefix='neostation-single-ipa-') as temp:
        root = Path(temp)
        with zipfile.ZipFile(ipa) as archive:
            demand(archive.testzip() is None, 'IPA ZIP CRC validation failed')
            names = archive.namelist()
            demand(len(names) == len(set(names)), 'IPA contains duplicate members')
            for member in archive.infolist():
                relative = Path(member.filename)
                demand(
                    not relative.is_absolute() and '..' not in relative.parts,
                    f'Unsafe IPA member: {member.filename}',
                )
            archive.extractall(root)

        payload = root / 'Payload'
        apps = sorted(path for path in payload.glob('*.app') if path.is_dir())
        demand(len(apps) == 1, 'The IPA must contain exactly one installable app')
        app = apps[0]
        all_apps = sorted(path for path in root.rglob('*.app') if path.is_dir())
        demand(
            all_apps == [app],
            'A second installable application was packaged with NeoStation',
        )

        extensions = sorted(path for path in root.rglob('*.appex') if path.is_dir())
        demand(
            all(path.parent == app / 'PlugIns' for path in extensions),
            'Every app extension must remain nested in NeoStation',
        )
        actual_extension_names = {path.name for path in extensions}
        demand(
            actual_extension_names == set(EXPECTED_EXTENSIONS),
            'Unexpected app-extension set: expected '
            f'{sorted(EXPECTED_EXTENSIONS)}, got {sorted(actual_extension_names)}',
        )

        app_info = load_plist(app / 'Info.plist')
        app_identifier = str(app_info.get('CFBundleIdentifier', ''))
        demand(app_info.get('CFBundlePackageType') == 'APPL', 'Invalid host type')
        host_executable = app / str(app_info.get('CFBundleExecutable', ''))
        host_entitlements = executable_entitlements(host_executable)
        require_runtime_entitlements(host_entitlements)
        reject_vpn_entitlements(host_entitlements, 'NeoStation')

        extension_reports = []
        for extension in extensions:
            contract = EXPECTED_EXTENSIONS[extension.name]
            info = load_plist(extension / 'Info.plist')
            extension_identifier = str(info.get('CFBundleIdentifier', ''))
            extension_point = info.get('NSExtension', {}).get(
                'NSExtensionPointIdentifier'
            )
            principal = info.get('NSExtension', {}).get('NSExtensionPrincipalClass')
            demand(info.get('CFBundlePackageType') == 'XPC!',
                   f'{extension.name} has an invalid package type')
            demand(
                extension_identifier == app_identifier + contract['bundleSuffix'],
                f'{extension.name} bundle identifier is inconsistent',
            )
            demand(
                info.get('CFBundleVersion') == app_info.get('CFBundleVersion'),
                f'{extension.name} and NeoStation have different build numbers',
            )
            demand(
                extension_point == SHARE_EXTENSION_POINT,
                f'{extension.name} has an unexpected extension point: '
                f'{extension_point!r}',
            )
            demand(
                extension_point != PACKET_TUNNEL_EXTENSION_POINT,
                f'{extension.name} is a forbidden packet-tunnel provider',
            )
            demand(
                principal == contract['principalClass'],
                f'{extension.name} principal class is inconsistent',
            )
            demand(info.get(contract['marker']) == '1',
                   f'{extension.name} identity marker is missing')
            extension_executable = extension / str(info.get('CFBundleExecutable', ''))
            extension_entitlements = executable_entitlements(extension_executable)
            reject_vpn_entitlements(extension_entitlements, extension.name)
            extension_reports.append({
                'bundle': extension.name,
                'bundleIdentifier': extension_identifier,
                'extensionPoint': extension_point,
            })

        # Defense in depth: reject a VPN entitlement hidden in any additional
        # Mach-O image, even when the bundle layout itself looks correct.
        scanned_images = 0
        for candidate in app.rglob('*'):
            if not candidate.is_file():
                continue
            with candidate.open('rb') as stream:
                magic = stream.read(4)
            if magic not in MACHO_MAGICS:
                continue
            scanned_images += 1
            reject_vpn_entitlements(
                embedded_entitlements(candidate.read_bytes()),
                str(candidate.relative_to(app)),
            )

        return {
            'ipa': ipa.name,
            'installationUnits': 1,
            'hostBundleIdentifier': app_identifier,
            'embeddedExtensions': extension_reports,
            'embeddedPacketTunnelPresent': False,
            'networkExtensionEntitlementPresent': False,
            'externalJITTransport': 'LocalDevVPN',
            'userSignsOneIPA': True,
            'nestedSigningOrder': [
                *[
                    f'NeoStation.app/PlugIns/{name}'
                    for name in sorted(EXPECTED_EXTENSIONS)
                ],
                'NeoStation.app',
            ],
            'machOImagesCheckedForVPNEntitlements': scanned_images,
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    try:
        report = validate(args.ipa)
    except (DistributionError, ValueError, plistlib.InvalidFileException) as exc:
        raise SystemExit(f'Single-IPA validation failed: {exc}') from exc
    output = json.dumps(report, indent=2, sort_keys=True) + '\n'
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding='utf-8')
    print(output, end='')


if __name__ == '__main__':
    main()
