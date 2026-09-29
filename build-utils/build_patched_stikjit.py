#!/usr/bin/env python3
"""Build/install the canonical StikJIT pin for every iOS version and host path.

No official/donor framework mix and no expiring native-artifact dependency.
Run on macOS with the selected Xcode and xcodegen available.
"""
from pathlib import Path
import hashlib
import json
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
PIN = json.loads((ROOT/'build-utils/stikjit/source.json').read_text())
SOURCE = ROOT/'.native-sources/StikJIT'
OUTPUT = ROOT/'build/stikjit-current'


def run(*args, cwd=ROOT):
    subprocess.run([str(a) for a in args], cwd=cwd, check=True)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def input_fingerprint():
    inputs = ['build-utils/stikjit/source.json','build-utils/patch_stikjit_rpcs3.py',
              'build-utils/patch_stikjit_compat.py','build-utils/install_patched_stikjit.py',
              'build-utils/build_patched_stikjit.py']
    return hashlib.sha256(json.dumps({p:sha(ROOT/p) for p in inputs},sort_keys=True).encode()).hexdigest()


def main():
    if sys.platform != 'darwin':
        raise SystemExit('The StikJIT iOS source build requires macOS/Xcode')
    OUTPUT.mkdir(parents=True, exist_ok=True)
    if not SOURCE.exists():
        SOURCE.parent.mkdir(parents=True, exist_ok=True)
        run('git','clone','--no-checkout',PIN['repository'],SOURCE)
        run('git','checkout','--detach',PIN['revision'],cwd=SOURCE)
    revision = subprocess.check_output(['git','rev-parse','HEAD'],cwd=SOURCE,text=True).strip()
    if revision != PIN['revision']:
        raise SystemExit('Generated StikJIT source has a different HEAD; use a clean build workspace')
    run(sys.executable,'build-utils/patch_stikjit_compat.py',SOURCE)
    run(sys.executable,'build-utils/patch_stikjit_compat.py',SOURCE)
    run(sys.executable,'test/stikjit_rpcs3_patch_test.py',SOURCE)
    run(sys.executable,'test/stikjit_compat_test.py',SOURCE)
    run(sys.executable,'test/stikjit_modern_baseline_test.py')
    run(sys.executable,'test/stikjit_scoped_host_test.py')
    run('node','test/rpcs3_debugger_handshake_test.js')
    run(sys.executable,'test/rpcs3_reporter_send_order_test.py')
    run(sys.executable,'test/local_dev_vpn_route_contract_test.py')
    run('xcodegen','generate',cwd=SOURCE)
    archive = SOURCE/'build/StikJIT-iOS.xcarchive'
    command = ['xcodebuild','archive','-project','StikJIT.xcodeproj','-scheme','StikJIT',
               '-destination','generic/platform=iOS','-archivePath',str(archive),
               'SKIP_INSTALL=NO','BUILD_LIBRARY_FOR_DISTRIBUTION=YES','CODE_SIGNING_ALLOWED=NO',
               'GENERATE_INFOPLIST_FILE=YES','MARKETING_VERSION='+PIN['version'],
               'CURRENT_PROJECT_VERSION=10','INFOPLIST_KEY_CFBundleShortVersionString='+PIN['version'],
               'INFOPLIST_KEY_CFBundleVersion=10']
    with (OUTPUT/'build.log').open('w') as log:
        result = subprocess.run(command,cwd=SOURCE,stdout=log,stderr=subprocess.STDOUT)
    if result.returncode:
        print((OUTPUT/'build.log').read_text()[-18000:])
        raise SystemExit(result.returncode)
    xc = OUTPUT/'StikJIT.xcframework'
    if xc.exists():
        shutil.rmtree(xc)  # only this generated build output
    run('xcodebuild','-create-xcframework','-framework',
        archive/'Products/Library/Frameworks/StikJIT.framework','-output',xc)
    fingerprint = input_fingerprint()
    origin = dict(PIN, sourceInputsSha256=fingerprint, verifiedCheckout=revision)
    (xc/'neostation-source.json').write_text(json.dumps(origin,indent=2)+'\n')
    run(sys.executable,'build-utils/install_patched_stikjit.py',xc)
    shutil.copy2(ROOT/'build/dolphin-ci/stikjit-release.json',OUTPUT/'identity.json')
    shutil.copy2(ROOT/'build/stikjit-tests/modern-baseline.json',OUTPUT/'modern-baseline.json')
    shutil.copy2(xc/'neostation-source.json',OUTPUT/'source-identity.json')
    zipped = OUTPUT/'StikJIT.xcframework.zip'
    zipped.unlink(missing_ok=True)
    run('zip','-qry',zipped,'StikJIT.xcframework',cwd=OUTPUT)
    (OUTPUT/'archive.sha256').write_text(sha(zipped)+'  StikJIT.xcframework.zip\n')
    host = subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip()
    (OUTPUT/'host-commit.txt').write_text(host+'\n')
    identity = ROOT/'build/fast-native/identity.json'
    if identity.is_file():
        info = json.loads(identity.read_text())
        info.update(stikjitNativeArchiveSha256=sha(zipped),stikjitBuiltFromSource=True,
                    stikjitSourceInputsSha256=fingerprint)
        identity.write_text(json.dumps(info,indent=2)+'\n')
    print('PASS: source-built StikJIT '+PIN['version']+' installed for all host/helper targets')


if __name__ == '__main__':
    main()
