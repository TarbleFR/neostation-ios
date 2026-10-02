#!/usr/bin/env python3
"""Configure only NeoPlay LAN permissions in an already-generated iOS host."""
from pathlib import Path
import argparse
import json
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STRINGS = json.loads((ROOT / 'build-utils/neoplay/local-network.json').read_text(encoding='utf-8'))
SERVICES = ['_neoplay._tcp', '_googlecast._tcp', '_CC1AD845._googlecast._tcp']

def configure(ios: Path) -> None:
    runner = ios / 'Runner'
    info_path = runner / 'Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    existing = info.get('NSBonjourServices', [])
    if not isinstance(existing, list):
        raise ValueError('NSBonjourServices must be an array')
    info['NSBonjourServices'] = list(dict.fromkeys(existing + SERVICES))
    info['NSLocalNetworkUsageDescription'] = STRINGS['en']
    # Do not introduce a global ATS exemption, or remove existing app policies.
    info.setdefault('NSAppTransportSecurity', {})['NSAllowsLocalNetworking'] = True
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    for language, message in STRINGS.items():
        language = {'zh': 'zh-Hans', 'zh_Hant': 'zh-Hant'}.get(language, language)
        target = runner / (language + '.lproj') / 'InfoPlist.strings'
        target.parent.mkdir(parents=True, exist_ok=True)
        text = target.read_text(encoding='utf-8') if target.exists() else ''
        entry = '"NSLocalNetworkUsageDescription" = ' + json.dumps(message, ensure_ascii=False) + ';'
        pattern = r'(?m)^[ \t]*"?NSLocalNetworkUsageDescription"?\s*=\s*"(?:\\.|[^"\\])*"\s*;'
        text = re.sub(pattern, lambda _: entry, text) if re.search(pattern, text) else text.rstrip() + '\n' + entry + '\n'
        target.write_text(text, encoding='utf-8')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--ios', type=Path, default=ROOT / 'ios')
    parser.add_argument('--no-xcode-resources', action='store_true')
    args = parser.parse_args()
    configure(args.ios)
    if not args.no_xcode_resources:
        subprocess.run(['ruby', str(ROOT / 'build-utils/neoplay_resources.rb'), str(args.ios)], check=True)
    print('NeoPlay LAN permissions configured; existing emulator capabilities preserved.')
