"""Reject reuse if an input outside the reviewed library/RetroArch delta changed.

Historical results retain their real SHA; this is not new simulator evidence.
The closed tree comparison includes tests, lockfiles, native recipes and assets.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REFERENCE = 'af0d539b4b8b3b95fe0434fc1f72c74d7c0b6eca'
REFERENCE_RUN = 37781416715
DELTA = {
    'lib/data/datasources/sqlite_database_service.dart',
    'lib/data/datasources/sqlite_service.dart', 'lib/main.dart',
    'lib/providers/sqlite_config_provider.dart',
    'lib/providers/sqlite_config_provider/scanning.dart',
    'lib/repositories/system_repository.dart',
    'lib/screens/settings_screen/new_settings_options/directories_settings_content.dart',
    'lib/screens/systems_screen/system_content.dart', 'lib/services/config_service.dart',
    'lib/services/game/game_launch_service.dart',
    'lib/services/ios_rom_library_root_resolver.dart',
    'lib/services/retroarch_library_protocol.dart',
    'lib/services/retroarch_library_service.dart',
    'lib/services/retroarch_folder_recovery.dart',
    'lib/services/retroarch_library_importer.dart',
    'packages/external_folder_access/ios/Classes/ExternalFolderAccessPlugin.swift',
    'packages/external_folder_access/ios/Classes/RetroArchURLHandoff.swift',
    'packages/external_folder_access/lib/external_folder_access.dart',
    'test/armsx2_retroarch_routing_isolation_test.dart',
    'test/ios_selective_rollback_test.dart', 'test/retroarch_folder_recovery_test.dart',
    'test/retroarch_library_restoration_test.dart',
    'test/retroarch_library_cache_test.dart', 'test/retroarch_sync_locale_test.dart',
    'test/retroarch_url_handoff_test.swift', 'test/retroarch_launch_diagnostics_test.dart',
    'test/retroarch_baseline_scope_test.py', 'test/retroarch_real_export_test.dart',
    'test/retroarch_playlist_repair_test.py',
    'test/fixtures/retroarch_handoff/ConsentTests.swift',
    'test/fixtures/retroarch_handoff/LegacyRetroArchURLHandoff.swift',
    'test/fixtures/retroarch_handoff/Receiver.swift',
    'test/fixtures/retroarch_handoff/Sender.swift',
    'test/library_scan_restart_test.dart', 'test/delivery_pipeline_test.py',
    'build-utils/verify_delivery_reuse.py', 'build-utils/delivery_metrics.py',
    'build-utils/sign_delivery.py', 'build-utils/delivery_benchmark.py',
    'build-utils/delivery_cipher.py', 'build-utils/delivery-422-recipient.pem',
}
INPUT_ROOTS = ('lib/', 'packages/', 'native/', 'build-utils/', 'assets/', 'test/')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def verify_tree():
    old = {}
    tree = subprocess.check_output(['git', 'ls-tree', '-r', REFERENCE], cwd=ROOT, text=True)
    for line in tree.splitlines():
        metadata, path = line.split('\t', 1)
        if path.startswith(INPUT_ROOTS) or path in ('pubspec.yaml', 'pubspec.lock'):
            old[path] = metadata.split()
    current = set(subprocess.check_output(['git', 'ls-files'], cwd=ROOT, text=True).splitlines())
    current = {p for p in current if p.startswith(INPUT_ROOTS) or p in ('pubspec.yaml', 'pubspec.lock')}
    changed = []
    unchanged = {}
    for path in sorted(set(old) | current):
        file = ROOT / path
        data = file.read_bytes() if file.is_file() else None
        oid = hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest() if data is not None else None
        if path not in old or old[path][2] != oid:
            if path not in DELTA:
                raise ValueError('Unreviewed validation input changed: ' + path)
            changed.append(path)
        else:
            mode = '100755' if file.stat().st_mode & 0o111 else '100644'
            if mode != old[path][0]:
                raise ValueError('Validation input mode changed: ' + path)
            unchanged[path] = sha(data)
    return changed, unchanged

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--offline', action='store_true')
    parser.add_argument('--output', default='build/delivery/reused-validation.json')
    args = parser.parse_args()
    changed, unchanged = verify_tree()
    run = None
    if not args.offline:
        run = json.loads(subprocess.check_output(['gh', 'api', f'repos/TarbleFR/neostation-ios/actions/runs/{REFERENCE_RUN}']))
        if run['head_sha'] != REFERENCE or run['conclusion'] != 'success' or run['path'] != '.github/workflows/neoswap-ipa.yml':
            raise ValueError('Historical complete build was not successful at the exact reference')
        jobs = json.loads(subprocess.check_output(['gh', 'api', f'repos/TarbleFR/neostation-ios/actions/runs/{REFERENCE_RUN}/jobs']))['jobs']
        build = next(j for j in jobs if 'private IPA' in j['name'])
        if build['conclusion'] != 'success' or any(s['conclusion'] != 'success' for s in build['steps']):
            raise ValueError('Historical build contains failed or skipped checks')
    report = {'referenceSHA': REFERENCE, 'referenceRun': REFERENCE_RUN,
              'onlineSuccessVerified': run is not None,
              'unchangedInputCount': len(unchanged),
              'unchangedInputsSha256': sha(json.dumps(unchanged, sort_keys=True).encode()),
              'changedInputsRequiringNewTests': changed,
              'deviceGameplayValidated': False}
    out = ROOT / args.output
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))

if __name__ == '__main__':
    main()
