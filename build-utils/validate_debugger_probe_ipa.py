"""Fail packaging if the reviewed RPCS3-only debugger script is not embedded."""
from pathlib import Path
import sys
import zipfile

root = Path(__file__).resolve().parents[1]
expected = (root / 'packages/rpcs3_jit_helper/ios/Resources/rpcs3-universal.js').read_bytes()
with zipfile.ZipFile(sys.argv[1]) as ipa:
    matches = [name for name in ipa.namelist()
               if '/PlugIns/' in name and name.endswith('/rpcs3-universal.js')]
    if not matches:
        raise SystemExit('RPCS3 helper has no bundled debugger probe script')
    for name in matches:
        if ipa.read(name) != expected:
            raise SystemExit(f'Debugger script differs from reviewed source: {name}')
print('PASS: helper debugger probe script matches reviewed source')
