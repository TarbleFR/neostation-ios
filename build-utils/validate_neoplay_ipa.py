#!/usr/bin/env python3
"""Fail closed if the candidate IPA does not actually contain the NeoPlay plugin."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import plistlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {'en', 'es', 'ru', 'zh-Hans', 'zh-Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
MARKERS = (b'NeoPlayBridgePlugin', b'NPGameHUD', b'NPControllerBatteryMonitor', b'NPAirPlayMonitor', b'NPMuxer', b'GCKCastContext', b'neostation/neoplay')
SERVICES = {'_neoplay._tcp', '_googlecast._tcp', '_CC1AD845._googlecast._tcp'}
spec = importlib.util.spec_from_file_location('neoplay_host_macho', ROOT / 'packages/dolphin_internal_bridge/ci/verify_ipa.py')
host_macho = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host_macho)

def ios_version(value: str) -> tuple:
    parts = tuple(map(int, value.split('.')))
    assert 1 <= len(parts) <= 3, 'Invalid iOS version'
    return parts + (0,) * (3 - len(parts))

def validate(ipa: Path, build: str, commit: str) -> dict:
    assert len(commit) == 40 and all(c in '0123456789abcdef' for c in commit), 'Invalid source identity'
    with zipfile.ZipFile(ipa) as z:
        names = z.namelist()
        assert len(names) == len(set(names)), 'Duplicate IPA members'
        apps = [n[:-len('Info.plist')] for n in names if n.startswith('Payload/') and n.endswith('.app/Info.plist') and n.count('/') == 2]
        assert len(apps) == 1, 'Expected one iOS host'
        app = apps[0]
        info = plistlib.loads(z.read(app + 'Info.plist'))
        assert info['CFBundleVersion'] == build, 'Wrong candidate build'
        assert SERVICES <= set(info.get('NSBonjourServices', [])), 'NeoPlay discovery services missing'
        assert info.get('NSLocalNetworkUsageDescription'), 'LAN permission description missing'
        assert info.get('NSAppTransportSecurity', {}).get('NSAllowsLocalNetworking') is True, 'LAN ATS allowance missing'
        executable = info['CFBundleExecutable']
        assert '/' not in executable and executable not in ('.', '..'), 'Invalid host executable'
        assert not any(name.startswith(app + 'Frameworks/neoplay_bridge.framework/') for name in names), 'Static NeoPlay must not be embedded as a dynamic framework'
        binary = z.read(app + executable)
        image = host_macho.macho(binary)
        assert image['fileType'] == 2 and image['platform'] == 2, 'NeoPlay must be linked into the actual arm64 iOS executable'
        assert ios_version(image['minimumOS']) == (18, 0, 0), 'Native host dropped iOS 18'
        assert ios_version(info['MinimumOSVersion']) == (18, 0, 0), 'Host plist dropped iOS 18'
        assert not any('neoplay_bridge.framework' in item['path'] for item in image['dependencies']), 'Stale dynamic NeoPlay dependency'
        for marker in MARKERS:
            assert marker in binary, 'NeoPlay implementation missing: ' + marker.decode()
        for language in LANGUAGES:
            data = z.read(app + language + '.lproj/InfoPlist.strings')
            try:
                assert plistlib.loads(data).get('NSLocalNetworkUsageDescription'), language
            except plistlib.InvalidFileException:
                text = data.decode('utf-8')
                assert 'NSLocalNetworkUsageDescription' in text, language
        identity = json.loads(z.read(app + 'NeoPlay-build-identity.json'))
        assert identity['build'] == build and identity['commit'] == commit, 'Stale NeoPlay identity'
        assert identity['physicalTVValidation'] is False, 'Unverified TV validation claim'
        assert identity['nativeLinkage'] == 'static_framework' and identity['castSDK'] == '4.8.6', 'Stale NeoPlay linkage/dependency identity'
        assert app + 'NeoPlay-Pods-acknowledgements.plist' in names, 'Dependency acknowledgements missing'
    return {'build': build, 'commit': commit, 'neoplayPackaged': True, 'controllerBatteryPackaged': True,
            'appleTVSystemRoutePackaged': True, 'nativeLinkage': 'static_framework',
            'nativeImage': app + executable, 'nativeImageSHA256': hashlib.sha256(binary).hexdigest(),
            'physicalTVValidation': False, 'physicalControllerValidation': False}

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--build-number', required=True)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = validate(args.ipa, args.build_number, args.commit)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
