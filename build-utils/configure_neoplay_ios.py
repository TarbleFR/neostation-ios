#!/usr/bin/env python3
"""Configure NeoPlay's reviewed deployment floor and LAN permissions."""
from pathlib import Path
import argparse
import json
import os
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
STRINGS = json.loads((ROOT / 'build-utils/neoplay/local-network.json').read_text(encoding='utf-8'))
SERVICES = ['_neoplay._tcp', '_googlecast._tcp', '_CC1AD845._googlecast._tcp']

def version(value: str) -> tuple[int, ...]:
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', value):
        raise ValueError('Invalid numeric iOS deployment version: ' + value)
    return tuple(int(part) for part in value.split('.')) + (0,) * (3 - len(value.split('.')))

def deployment_floor() -> str:
    pod = (ROOT / 'packages/neoplay_bridge/ios/neoplay_bridge.podspec').read_text()
    matches = re.findall(r"s\.platform\s*=\s*:ios,\s*['\"]([^'\"]+)['\"]", pod)
    if len(matches) != 1:
        raise ValueError('NeoPlay must declare exactly one reviewed iOS deployment floor')
    version(matches[0])
    return matches[0]

def configure_deployment_files(ios: Path) -> str:
    """Change generated host files only; never lower a higher deployment floor."""
    minimum = deployment_floor()
    podfile = ios / 'Podfile'
    text = podfile.read_text()
    pattern = r"(?m)^([ \t]*)(#?[ \t]*)platform\s+:ios\s*,\s*(['\"])(\d+(?:\.\d+){0,2})\3"
    matches = list(re.finditer(pattern, text))
    if len(matches) != 1:
        raise ValueError('Generated Podfile must contain exactly one iOS platform')
    match = matches[0]
    current = match.group(4)
    target = minimum if version(current) < version(minimum) else current
    replacement = match.group(1) + "platform :ios, '" + target + "'"
    updated = text[:match.start()] + replacement + text[match.end():]
    framework = ios / 'Flutter/AppFrameworkInfo.plist'
    info = plistlib.loads(framework.read_bytes())
    current = info.get('MinimumOSVersion', minimum)
    if not isinstance(current, str):
        raise ValueError('Flutter MinimumOSVersion must be a numeric string')
    if version(current) < version(minimum):
        info['MinimumOSVersion'] = minimum
    elif 'MinimumOSVersion' not in info:
        info['MinimumOSVersion'] = minimum
    if updated != text:
        podfile.write_text(updated)
    rendered = plistlib.dumps(info, sort_keys=False)
    if rendered != framework.read_bytes():
        framework.write_bytes(rendered)
    return minimum

def ruby_command(script: str, *arguments: str) -> list[str]:
    prefix = ['bundle', 'exec'] if os.environ.get('BUNDLE_GEMFILE') else []
    return prefix + ['ruby', str(ROOT / script), *arguments]

def configure_deployment_target(ios: Path) -> None:
    minimum = configure_deployment_files(ios)
    subprocess.run(ruby_command('build-utils/neoplay_deployment.rb', str(ios), minimum), check=True)

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
    parser.add_argument('--deployment-only', action='store_true',
                        help='Align the generated host before Flutter invokes CocoaPods')
    args = parser.parse_args()
    configure_deployment_target(args.ios)
    if not args.deployment_only:
        configure(args.ios)
        if not args.no_xcode_resources:
            subprocess.run(ruby_command('build-utils/neoplay_resources.rb', str(args.ios)), check=True)
    print('NeoPlay generated-host deployment floor configured; existing emulator capabilities preserved.')
