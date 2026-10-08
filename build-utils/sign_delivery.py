"""Sign nested device code in order and verify every signature for SideStore.

Ad hoc signatures seal this input IPA; SideStore must apply Apple provisioning.
No private Apple identity or claim of device installation is made here.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile

def run(*args):
    return subprocess.check_output(args, stderr=subprocess.STDOUT)

def sign(app, report_path):
    bundles = [p for p in app.rglob('*') if p.is_dir() and p.suffix in ('.framework', '.appex', '.app')]
    loose = [p for p in app.rglob('*.dylib') if not any(q.suffix == '.framework' for q in p.parents)]
    targets = sorted(bundles + loose, key=lambda p: len(p.parts), reverse=True) + [app]
    reports = []
    with tempfile.TemporaryDirectory() as temporary:
        for index, target in enumerate(targets):
            args = ['codesign', '--force', '--sign', '-', '--timestamp=none']
            existing = {}
            # Preserve the existing scoped entitlements inserted by the reviewed
            # host/donor scripts. Frameworks receive no executable capabilities.
            if target.suffix in ('.app', '.appex'):
                try:
                    payload = run('codesign', '-d', '--entitlements', ':-', str(target))
                    start = payload.find(b'<?xml')
                    if start >= 0:
                        existing = plistlib.loads(payload[start:])
                except subprocess.CalledProcessError:
                    pass
                if existing:
                    path = Path(temporary) / f'{index}.plist'
                    path.write_bytes(plistlib.dumps(existing))
                    args += ['--entitlements', str(path)]
            run(*args, str(target))
        for target in targets:
            run('codesign', '--verify', '--strict', '--verbose=2', str(target))
            description = run('codesign', '-d', '--verbose=4', str(target)).decode()
            if 'Signature=adhoc' not in description:
                raise ValueError('Unexpected signing identity: ' + str(target))
            reports.append({'bundle': str(target.relative_to(app)) or '.',
                            'signatureVerified': True, 'signature': 'adhoc',
                            'appleProvisioningVerified': False})
        run('codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app))
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    executable = app / info['CFBundleExecutable']
    architectures = run('lipo', '-archs', str(executable)).decode().split()
    if 'arm64' not in architectures or info['CFBundleSupportedPlatforms'] != ['iPhoneOS']:
        raise ValueError('Delivery is not a physical ARM64 iPhone build')
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(json.dumps({'installationMethod': 'SideStore re-signing',
        'directAppleInstallationReady': False, 'deviceInstallationTested': False,
        'bundleIdentifier': info['CFBundleIdentifier'], 'build': info['CFBundleVersion'],
        'version': info['CFBundleShortVersionString'], 'minimumIOS': info['MinimumOSVersion'],
        'architectures': architectures, 'signatures': reports}, indent=2) + '\n')

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    parser.add_argument('--report', type=Path, default=Path('build/delivery/signature.json'))
    args = parser.parse_args()
    sign(args.app, args.report)
