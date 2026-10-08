"""Exercise URL transport in two disposable iOS simulator apps, not RetroArch."""
import json
import os
import pathlib
import platform
import plistlib
import subprocess
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'test/fixtures/retroarch_handoff'
OUT = pathlib.Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'retroarch-uikit-evidence.json'


def run(*args, env=None, check=True):
    result = subprocess.run(args, text=True, capture_output=True, env=env, timeout=240)
    if check and result.returncode:
        raise RuntimeError(f'{args!r}\n{result.stdout}\n{result.stderr}')
    return result.stdout.strip()


def main():
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    device_type = None
    runtime = None
    for key, group in devices.items():
        if 'iOS' in key:
            for item in group:
                if item.get('isAvailable') and 'iPhone' in item['name']:
                    runtime, device_type = key, item.get('deviceTypeIdentifier')
                    if device_type:
                        break
        if device_type:
            break
    if not device_type:
        raise RuntimeError('No installed iPhone simulator runtime')
    udid = run('xcrun', 'simctl', 'create', 'NeoStation handoff isolation', device_type, runtime)
    evidence = {'runtime': runtime, 'device': device_type, 'cases': [], 'scope': 'UIKit URL transport only; synthetic receiver'}
    try:
        run('xcrun', 'simctl', 'boot', udid)
        run('xcrun', 'simctl', 'bootstatus', udid, '-b')
        with tempfile.TemporaryDirectory(prefix='retroarch-handoff-') as tmp:
            sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
            target = f'{platform.machine()}-apple-ios17.0-simulator'
            for name, scheme in [('Sender', 'neostation-handoff-test'), ('Receiver', 'retroarch')]:
                bundle = pathlib.Path(tmp) / f'{name}.app'
                bundle.mkdir()
                info = {
                    'CFBundleExecutable': name, 'CFBundleIdentifier': f'org.neostation.handofftest.{name.lower()}',
                    'CFBundleName': name, 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                    'CFBundleShortVersionString': '1', 'MinimumOSVersion': '17.0',
                    'UIDeviceFamily': [1, 2], 'LSRequiresIPhoneOS': True,
                    'CFBundleURLTypes': [{'CFBundleURLSchemes': [scheme]}],
                    'UILaunchScreen': {},
                }
                if name == 'Receiver':
                    info['UIApplicationSceneManifest'] = {
                        'UIApplicationSupportsMultipleScenes': False,
                        'UISceneConfigurations': {'UIWindowSceneSessionRoleApplication': [{
                            'UISceneConfigurationName': 'Default', 'UISceneDelegateClassName': 'Receiver.ReceiverScene',
                        }]},
                    }
                (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
                sources = [str(FIXTURE / f'{name}.swift')]
                if name == 'Sender':
                    sources += [str(FIXTURE / 'LegacyRetroArchURLHandoff.swift'), str(ROOT / 'packages/external_folder_access/ios/Classes/RetroArchURLHandoff.swift')]
                run('xcrun', '--sdk', 'iphonesimulator', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', name,
                    '-target', target, '-sdk', sdk, *sources, '-o', str(bundle / name))
                run('codesign', '--force', '--sign', '-', str(bundle))
                run('xcrun', 'simctl', 'install', udid, str(bundle))
            sender = 'org.neostation.handofftest.sender'
            receiver = 'org.neostation.handofftest.receiver'
            sender_file = pathlib.Path(run('xcrun', 'simctl', 'get_app_container', udid, sender, 'data')) / 'Documents/result.json'
            receiver_file = pathlib.Path(run('xcrun', 'simctl', 'get_app_container', udid, receiver, 'data')) / 'Documents/received.json'
            for mode, host, cold in [('legacy', 'library', False), ('legacy', 'game', False), ('current', 'library', False), ('current', 'game', False), ('current', 'library', True)]:
                run('xcrun', 'simctl', 'terminate', udid, sender, check=False)
                run('xcrun', 'simctl', 'terminate', udid, receiver, check=False)
                sender_file.unlink(missing_ok=True); receiver_file.unlink(missing_ok=True)
                if not cold:
                    run('xcrun', 'simctl', 'launch', udid, receiver)
                    time.sleep(2)
                url = 'retroarch://library?scheme=neostation-handoff-test' if host == 'library' else 'retroarch://game/Unicode-%C3%A9.zip%23folder%2Fgame.gba'
                env = dict(os.environ, SIMCTL_CHILD_HANDOFF_MODE=mode, SIMCTL_CHILD_HANDOFF_TARGET=url)
                run('xcrun', 'simctl', 'launch', udid, sender, env=env)
                # Poll result within a finite bound; allow the receiver's callback
                # to finish after UIKit reports URL acceptance.
                deadline = time.monotonic() + 20
                events = []
                while time.monotonic() < deadline:
                    events = json.loads(sender_file.read_text()) if sender_file.exists() else []
                    if any(e['event'] == 'finished' for e in events):
                        time.sleep(2)
                        break
                    time.sleep(0.2)
                events = json.loads(sender_file.read_text()) if sender_file.exists() else []
                received = json.loads(receiver_file.read_text()) if receiver_file.exists() else []
                case = {'mode': mode, 'host': host, 'cold': cold, 'sender': events, 'receiver': received, 'delivered': url in received}
                evidence['cases'].append(case)
                OUT.write_text(json.dumps(evidence, indent=2))
                print(json.dumps(case), flush=True)
                assert any(e['event'] == 'finished' for e in events), 'sender did not finish'
                if mode == 'current' and not cold:
                    assert received == [url], 'functional URL must arrive exactly once'
                    assert [e['state'] for e in events if e['event'] == 'send'] == [0], 'send must occur while active'
                    if host == 'library':
                        assert any(e['event'] == 'callback' for e in events), 'library callback must reach sender'
                if cold:
                    assert not case['delivered'], 'fixture models upstream cold-scene omission'
            evidence['legacy_background_rejection_reproduced'] = all(
                not c['delivered'] and any(e['event'] == 'send' and e['state'] == 2 for e in c['sender'])
                for c in evidence['cases'] if c['mode'] == 'legacy')
            OUT.write_text(json.dumps(evidence, indent=2))
            print(f'Evidence: {OUT}; legacy rejected: {evidence["legacy_background_rejection_reproduced"]}')
    finally:
        run('xcrun', 'simctl', 'shutdown', udid, check=False)
        run('xcrun', 'simctl', 'delete', udid, check=False)


if __name__ == '__main__':
    main()
