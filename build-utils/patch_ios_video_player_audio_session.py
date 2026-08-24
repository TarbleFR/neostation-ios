#!/usr/bin/env python3
"""Keep video_player_avfoundation from owning AVAudioSession."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlparse

MARKER = 'NEOSTATION_AUDIO_SESSION_OWNED_EXTERNALLY'
RELATIVE_TARGET = Path(
    'darwin/video_player_avfoundation/Sources/'
    'video_player_avfoundation/VideoPlayerPlugin.swift'
)

def uri_path(value: str, base: Path) -> Path:
    parsed = urlparse(value)
    if parsed.scheme == 'file':
        return Path(unquote(parsed.path)).resolve()
    return (base / unquote(value)).resolve()

def locate_plugin_source() -> Path:
    config_path = Path('.dart_tool/package_config.json')
    if config_path.is_file():
        payload = json.loads(
            config_path.read_text(encoding='utf-8')
        )
        for package in payload.get('packages', []):
            if package.get('name') != 'video_player_avfoundation':
                continue
            root = uri_path(package['rootUri'], config_path.parent)
            target = root / RELATIVE_TARGET
            if target.is_file():
                return target

    candidates = sorted(
        Path.home().glob(
            '.pub-cache/hosted/pub.dev/'
            'video_player_avfoundation-*/'
            + str(RELATIVE_TARGET)
        )
    )
    if candidates:
        return candidates[-1]
    raise SystemExit(
        'video_player_avfoundation source not found; '
        'run flutter pub get first'
    )

def function_block(
    source: str,
    signature: str,
) -> tuple[int, int, str]:
    start = source.find(signature)
    if start < 0:
        raise SystemExit(f'Missing Swift function: {signature}')
    opening = source.find('{', start)
    if opening < 0:
        raise SystemExit(
            f'Missing opening brace for: {signature}'
        )

    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == '{':
            depth += 1
        elif char == '}':
            depth -= 1
            if depth == 0:
                return start, index + 1, source[start:index + 1]
    raise SystemExit(f'Unbalanced Swift function: {signature}')

def verify(source: str) -> None:
    _, _, initialize = function_block(
        source,
        '  func initialize() throws {',
    )
    if MARKER not in initialize:
        raise SystemExit(
            'video_player initialize() is not NeoStation-owned'
        )
    if 'requestedCategory: .playback' in initialize:
        raise SystemExit(
            'video_player still upgrades AVAudioSession to .playback'
        )

    _, _, mix = function_block(
        source,
        '  func setMixWithOthers(_ mixWithOthers: Bool) throws {',
    )
    if MARKER not in mix:
        raise SystemExit('setMixWithOthers() is not neutralized')
    if 'upgradeAudioSessionCategory' in mix or 'setCategory' in mix:
        raise SystemExit(
            'setMixWithOthers() still mutates AVAudioSession'
        )

def patch(target: Path) -> None:
    source = target.read_text(encoding='utf-8')
    if MARKER not in source:
        pattern = re.compile(
            r'(?ms)^    #if os\(iOS\)\n'
            r'      // Allow audio playback when the Ring/Silent '
            r'switch is set to silent\n'
            r'      upgradeAudioSessionCategory\(\n.*?'
            r'^    #endif\n'
        )
        replacement = (
            '    #if os(iOS)\n'
            f'      // {MARKER}\n'
            '      // NeoStation configures the single shared '
            'AVAudioSession.\n'
            '      // The plugin must not upgrade `.ambient` '
            'to `.playback`.\n'
            '    #endif\n'
        )
        source, count = pattern.subn(
            replacement,
            source,
            count=1,
        )
        if count != 1:
            raise SystemExit(
                'Could not find video_player iOS .playback block'
            )

        start, end, _ = function_block(
            source,
            '  func setMixWithOthers('
            '_ mixWithOthers: Bool) throws {',
        )
        replacement_function = (
            '  func setMixWithOthers('
            '_ mixWithOthers: Bool) throws {\n'
            f'    // {MARKER}\n'
            '    // Per-player mixing hints must not reconfigure '
            'the app-wide\n'
            '    // AVAudioSession owned by NeoStation.\n'
            '    _ = mixWithOthers\n'
            '  }'
        )
        source = (
            source[:start]
            + replacement_function
            + source[end:]
        )
        target.write_text(source, encoding='utf-8')

    verify(target.read_text(encoding='utf-8'))
    print(
        'Verified NeoStation audio-session ownership patch: '
        f'{target}'
    )

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()

    target = locate_plugin_source()
    if args.check:
        verify(target.read_text(encoding='utf-8'))
        print(
            'Verified NeoStation audio-session ownership patch: '
            f'{target}'
        )
    else:
        patch(target)
    return 0

if __name__ == '__main__':
    sys.exit(main())
