#!/usr/bin/env python3
"""Fail closed if the candidate IPA does not actually contain the NeoPlay plugin."""
from pathlib import Path
import argparse
import hashlib
import json
import plistlib
import zipfile

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = {'en', 'es', 'ru', 'zh-Hans', 'zh-Hant', 'pt', 'fr', 'de', 'it', 'id', 'ja', 'ko'}
MARKERS = (b'NeoPlayBridgePlugin', b'NPGameHUD', b'NPControllerBatteryMonitor', b'NPAirPlayMonitor', b'NPMuxer', b'GCKCastContext', b'neostation/neoplay')
SERVICES = {'_neoplay._tcp', '_googlecast._tcp', '_CC1AD845._googlecast._tcp'}

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
        bridge = app + 'Frameworks/neoplay_bridge.framework/neoplay_bridge'
        assert bridge in names, 'NeoPlay Flutter native plugin not packaged'
        binary = z.read(bridge)
        assert binary[:4] in (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'), 'NeoPlay is not a Mach-O image'
        for marker in MARKERS:
            assert marker in binary, 'NeoPlay implementation missing: ' + marker.decode()
        framework_info = plistlib.loads(z.read(app + 'Frameworks/neoplay_bridge.framework/Info.plist'))
        assert tuple(map(int, framework_info.get('MinimumOSVersion', '999').split('.'))) <= (18, 0), 'NeoPlay dropped iOS 18'
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
        assert app + 'NeoPlay-Pods-acknowledgements.plist' in names, 'Dependency acknowledgements missing'
    return {'build': build, 'commit': commit, 'neoplayPackaged': True, 'controllerBatteryPackaged': True,
            'appleTVSystemRoutePackaged': True, 'bridgeSHA256': hashlib.sha256(binary).hexdigest(),
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
