#!/usr/bin/env python3
"""Audit the authorized cloud-provider replacement against the shipped 207 tree.

Native cores, JIT, framework packaging, emulator launch implementations, media,
licensing and dependency versions are not allowed to change with this migration.
Catalog changes are limited to a save-config key migration. Launch-file changes
outside explicit cloud/native-Dolphin lifecycle blocks remain fatal.
"""
from __future__ import annotations
import argparse
import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE = '09b3fb3ac851b327732aeb8aa8f6e3e4749dfce6'

def git(*args: str) -> str:
    return subprocess.check_output(['git', *args], cwd=ROOT, text=True)

def text(path: str) -> str:
    return (ROOT / path).read_text()

def previous(base: str, path: str) -> str:
    return git('show', f'{base}:{path}')

def compact(value: str) -> str:
    return re.sub(r'\s+', '', value)

def remove_blocks(value: str, marker: str) -> str:
    out, inside = [], False
    for line in value.splitlines():
        if marker + '_BEGIN' in line:
            assert not inside, f'nested {marker}'
            inside = True
        if not inside:
            out.append(line)
        if marker + '_END' in line:
            assert inside, f'unmatched {marker}'
            inside = False
    assert not inside, f'unclosed {marker}'
    return '\n'.join(out)

def require(value: str, *needles: str) -> None:
    for needle in needles:
        assert compact(needle) in compact(value), f'Missing safety invariant: {needle}'

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--base', default=BASE)
    args = parser.parse_args()
    review = json.loads(text('docs/ICLOUD_MIGRATION_SCOPE.json'))
    assert review['base'] == BASE
    changed = set(git('diff', '--name-only', args.base).splitlines())
    changed.update(git('ls-files', '--others', '--exclude-standard').splitlines())
    unexpected = changed - set(review['authorizedPaths'])
    assert not unexpected, f'Changes outside reviewed migration scope: {sorted(unexpected)}'

    # byte-identical native engines, JIT bridges, framework validation/build code
    protected = ('packages/dolphin_internal_bridge/', 'packages/dolphin_jit_helper/',
                 'packages/stikjit_bridge/', 'native/', 'lib/services/retroarch_',
                 'lib/services/armsx2_', 'lib/services/melonx_', 'lib/services/rpcs3_')
    exceptions = {'packages/dolphin_internal_bridge/ci/build_support.py',
                  'lib/services/armsx2_folder_service.dart', 'lib/services/retroarch_config_service.dart'}
    for path in git('ls-tree', '-r', '--name-only', args.base).splitlines():
        if (path.startswith(protected) and path not in exceptions) or path in {
            'pubspec.yaml', 'pubspec.lock', 'pubspec_overrides.yaml', 'LICENSE.md', 'NOTICE.md',
            'lib/services/music_player_service.dart', 'lib/services/sfx_service.dart',
            'lib/services/audio_policy_service.dart', 'lib/services/dolphin_system_files.dart',
            'build-utils/patch_dolphin_internal_core_v2.py', 'build-utils/configure_dolphin_ios_v2.py',
            'build-utils/materialize_dolphin_isolated_v2.py'}:
            expected = git('rev-parse', f'{args.base}:{path}').strip()
            assert (ROOT / path).is_file(), f'Protected source deleted: {path}'
            assert git('hash-object', path).strip() == expected, f'Protected source changed: {path}'
    for path in changed:
        if path.startswith('assets/systems/'):
            before, after = json.loads(previous(args.base, path)), json.loads(text(path))
            def migrate_keys(value):
                if isinstance(value, dict):
                    return {('save_sync' if k == 'neosync' else k): migrate_keys(v) for k, v in value.items()}
                if isinstance(value, list): return [migrate_keys(v) for v in value]
                return value
            before = migrate_keys(before)
            assert before == after, f'Unrelated emulator catalog data changed: {path}'

    # Source snapshot path list may change, never compiler/linker/packaging logic.
    path = 'packages/dolphin_internal_bridge/ci/build_support.py'
    strip_snapshot = lambda s: re.sub(r'def source_snapshot\(\).*?(?=\ndef generate_plugin_registrant)', '', s, flags=re.S)
    assert strip_snapshot(previous(args.base, path)) == strip_snapshot(text(path)), 'Native build pipeline changed'
    for path in ('lib/services/armsx2_folder_service.dart', 'lib/services/retroarch_config_service.dart'):
        before = previous(args.base, path).replace('NeoSync', 'SaveSync').replace('neosync', 'save_sync')
        after = text(path).replace('iCloud Saves', 'SaveSync').replace('cloud_saves', 'save_sync')
        # Only naming/compatibility bookmark changes; compare code, not comments.
        normal = lambda s: compact(re.sub(r'//[^\n]*', '', s))
        if path.endswith('armsx2_folder_service.dart'):
            before = before.replace('legacySaveSyncBookmarkKey', 'legacySaveBookmarkKey').replace('save_sync-armsx2-saves', 'armsx2-save-folder')
        assert normal(before) == normal(after), f'Native emulator folder logic changed: {path}'

    launcher = text('lib/services/game/game_launch_service.dart')
    before = remove_blocks(previous(args.base, 'lib/services/game/game_launch_service.dart'), 'DOLPHIN_ISOLATION')
    after = remove_blocks(remove_blocks(launcher, 'DOLPHIN_ISOLATION'), 'CLOUD_SAVES')
    assert compact(before) == compact(after), 'An unrelated game launch route changed'
    require(launcher, 'DolphinInternalV2Service.isDolphinSystem', 'DolphinInternalV2Service.launch',
        'Rpcs3LaunchService.launchTitle', 'MelonxLibraryService.launchGameByRomPath',
        'Armsx2LibraryService.launchGameByRomPath', 'RetroArchLibraryService.launchGameByRomPath')
    require(text('packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift'), 'script: .legacy')
    service = text('lib/services/dolphin_internal_v2_service.dart')
    require(service, "normalized == 'gc' || normalized == 'wii'", 'withSaveAccess')
    assert "'elf'" not in service and "'dol'" not in service

    provider = text('lib/providers/icloud_save_provider.dart')
    require(provider, "providerId => 'icloud'", 'connected && enabled && _scope.isNotEmpty',
        'await _restoring?.future', 'gameIsRunning()', '_deletedKey', 'payloadHash', 'contentHash')
    for removed in ('lib/providers/neo_sync_provider.dart', 'lib/services/neosync', 'lib/providers/neosync',
                    'lib/screens/neo_sync_screen', 'lib/services/notification_service.dart'):
        assert not (ROOT / removed).exists(), f'Old server/account flow remains: {removed}'
    for path in (ROOT / 'lib').rglob('*.dart'):
        if path.name == 'legacy_save_migration.dart': continue
        assert not re.search(r'neo_?sync', path.read_text(), re.I), f'Old provider reference remains: {path}'
    broker = text('packages/external_folder_access/ios/Classes/ICloudFolderPlugin.swift')
    require(broker, 'NSFileCoordinator()', '.isUbiquitousItemKey', 'startAccessingSecurityScopedResource()',
        'stopAccessingSecurityScopedResource()', 'restoreFolderContents', 'preserveModificationDates',
        'assertNoLinks', 'SHA256', '.ubiquitousItemIsUploadedKey', 'ACCOUNT_CHANGED')
    require(text('lib/services/cloud_saves/save_snapshot.dart'), 'NSCS0001', 'maxMembers', 'noLinks', 'sha256')
    print(f'iCloud migration scope passed: {len(changed)} reviewed paths; native/JIT/audio/dependency protection preserved.')

if __name__ == '__main__':
    main()
