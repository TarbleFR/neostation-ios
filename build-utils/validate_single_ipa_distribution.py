#!/usr/bin/env python3
"""Validate that NeoStation ships as one re-signable IPA with one nested VPN.

The user's signer must process the embedded app extension before the containing
application, but the user installs and signs only the resulting NeoStation IPA.
This validator rejects layouts that would require a second IPA or a separately
installed LocalTunnel application.
"""
from __future__ import annotations

import argparse
import json
import plistlib
import tempfile
import zipfile
from pathlib import Path

from embed_rpcs3_host_entitlements import (
    LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS,
    embedded_entitlements,
    require_entitlements,
)


class DistributionError(RuntimeError):
    pass


def demand(condition: bool, message: str) -> None:
    if not condition:
        raise DistributionError(message)


def load_plist(path: Path) -> dict:
    payload = plistlib.loads(path.read_bytes())
    demand(isinstance(payload, dict), f'Invalid property list: {path}')
    return payload


def validate(ipa: Path) -> dict:
    demand(ipa.is_file() and zipfile.is_zipfile(ipa), f'Invalid IPA: {ipa}')
    with tempfile.TemporaryDirectory(prefix='neostation-single-ipa-') as temp:
        root = Path(temp)
        with zipfile.ZipFile(ipa) as archive:
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
        expected_extension = app / 'PlugIns/NeoStationLocalTunnel.appex'
        demand(
            extensions.count(expected_extension) == 1,
            'The local tunnel extension is missing or duplicated',
        )
        demand(
            all(path.parent == app / 'PlugIns' for path in extensions),
            'Every app extension must remain nested in NeoStation',
        )

        app_info = load_plist(app / 'Info.plist')
        extension_info = load_plist(expected_extension / 'Info.plist')
        app_identifier = str(app_info.get('CFBundleIdentifier', ''))
        extension_identifier = str(
            extension_info.get('CFBundleIdentifier', '')
        )
        demand(app_info.get('CFBundlePackageType') == 'APPL', 'Invalid host type')
        demand(
            extension_info.get('CFBundlePackageType') == 'XPC!',
            'The local tunnel is not packaged as an app extension',
        )
        demand(
            extension_identifier == f'{app_identifier}.localtunnel',
            'The local tunnel identifier is not a child of NeoStation',
        )
        demand(
            extension_info.get('CFBundleVersion') == app_info.get('CFBundleVersion'),
            'NeoStation and its local tunnel have different build numbers',
        )
        demand(
            extension_info.get('NSExtension', {}).get(
                'NSExtensionPointIdentifier'
            ) == 'com.apple.networkextension.packet-tunnel',
            'The nested extension is not a packet-tunnel provider',
        )

        host_executable = app / str(app_info.get('CFBundleExecutable', ''))
        extension_executable = expected_extension / str(
            extension_info.get('CFBundleExecutable', '')
        )
        demand(host_executable.is_file(), 'NeoStation executable is missing')
        demand(extension_executable.is_file(), 'Local tunnel executable is missing')
        host_entitlements = embedded_entitlements(host_executable.read_bytes())
        extension_entitlements = embedded_entitlements(
            extension_executable.read_bytes()
        )
        require_entitlements(
            host_entitlements,
            LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS,
            'NeoStation',
        )
        require_entitlements(
            extension_entitlements,
            LOCAL_TUNNEL_EXTENSION_ENTITLEMENTS,
            'NeoStationLocalTunnel',
        )
        obsolete = 'com.apple.developer.networking.vpn.api'
        demand(
            obsolete not in host_entitlements and
            obsolete not in extension_entitlements,
            'Personal VPN entitlement must not be mixed with packet tunnel signing',
        )

        return {
            'ipa': ipa.name,
            'installationUnits': 1,
            'hostBundleIdentifier': app_identifier,
            'embeddedTunnelBundleIdentifier': extension_identifier,
            'embeddedExtensions': [path.name for path in extensions],
            'separateTunnelIPARequired': False,
            'userSignsOneIPA': True,
            'nestedSigningOrder': [
                *[f'NeoStation.app/PlugIns/{path.name}' for path in extensions],
                'NeoStation.app',
            ],
            'requiredCapability': 'packet-tunnel-provider',
            'obsoletePersonalVPNCapabilityPresent': False,
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
