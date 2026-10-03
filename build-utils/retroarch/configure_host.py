#!/usr/bin/env python3
"""Configure only generated Runner metadata required by the RetroArch bridge.

Run after the established emulator configurators and before CocoaPods/Xcode.
No RetroArch linker or copy phase is added: embed_package.py installs the
validated lazy-loaded runtime into the already-built unsigned app.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]


def version(value: str) -> tuple[int, int]:
    pieces = str(value).split('.')
    if not all(piece.isdigit() for piece in pieces):
        raise ValueError(f'Generated iOS deployment version is not numeric: {value}')
    return tuple(map(int, (pieces + ['0'])[:2]))


def configure_info(path: Path) -> None:
    data = plistlib.loads(path.read_bytes())
    if not isinstance(data, dict):
        raise ValueError('Runner Info.plist must be a dictionary')
    data['UIFileSharingEnabled'] = True
    data['LSSupportsOpeningDocumentsInPlace'] = True
    if version(data.get('MinimumOSVersion', '0')) < (18, 0):
        data['MinimumOSVersion'] = '18.0'
    path.write_bytes(plistlib.dumps(data, fmt=plistlib.FMT_XML, sort_keys=False))


def configure_podfile(path: Path) -> None:
    text = path.read_text(encoding='utf-8')
    pattern = re.compile(r"^[ \t]*#?[ \t]*platform[ \t]+:ios,[ \t]*'([0-9.]+)'[ \t]*$", re.MULTILINE)
    matches = list(pattern.finditer(text))
    if len(matches) > 1:
        raise ValueError('Ambiguous generated Podfile iOS platform declaration')
    if matches:
        match = matches[0]
        deployment = match[1] if version(match[1]) >= (18, 0) else '18.0'
        text = text[:match.start()] + f"platform :ios, '{deployment}'" + text[match.end():]
    else:
        text = "platform :ios, '18.0'\n" + text
    path.write_text(text, encoding='utf-8')


def configure(ios: Path, edit_project: bool = True) -> dict:
    runner = ios / 'Runner'
    project = ios / 'Runner.xcodeproj'
    if not (runner / 'Info.plist').is_file() or not (ios / 'Podfile').is_file() or not project.is_dir():
        raise ValueError('Generated Flutter iOS scaffold is incomplete')
    configure_info(runner / 'Info.plist')
    configure_podfile(ios / 'Podfile')
    if edit_project:
        subprocess.run(['ruby', str(Path(__file__).with_suffix('.rb')), str(project)], check=True)
    return {'success': True, 'minimumOS': '18.0', 'documentsShared': True,
            'documentsEditableInPlace': True, 'runtimeEmbedding': 'post-build-validated-copy',
            'modifiedExistingEmulatorTargets': False}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ios-root', type=Path, default=ROOT / 'ios')
    parser.add_argument('--scaffold', action='store_true', help='Use the existing generated Flutter host scaffold helper first')
    args = parser.parse_args()
    if args.scaffold:
        subprocess.run([sys.executable, str(ROOT / 'packages/dolphin_internal_bridge/ci/build_support.py'), 'scaffold'],
                       cwd=ROOT, check=True)
    print(json.dumps(configure(args.ios_root.resolve()), indent=2))


if __name__ == '__main__':
    main()
