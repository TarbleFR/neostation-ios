#!/usr/bin/env python3
"""Reuse only the byte-verified RPCS3 core from successful Build 266.

Host-only releases change account/tunnel handling, not the emulation core.
Unexpected source changes refuse reuse. StikJIT and the app are rebuilt;
Dolphin retains its existing source-hash cache checks.
"""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BASE = '013d5fc5082e3e3af28e27c7409a1c030086ee9a'
IPA_SHA256 = 'caf5861359b8578d7315a4678064c53882b85961fe8dcd207f92332fac63999b'
CORE_SHA256 = 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'
ALLOWED = {
    '.github/workflows/build-ipa-once.yml',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinRetroAchievementsAccount.h',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinRetroAchievementsAccount.mm',
    'build-utils/patch_dolphin_build267_account.py',
    'build-utils/reuse_build266_rpcs3_for267.py',
    'build-utils/validate_build266_identity.py',
    'test/dolphin_account_267_test.py',
    'test/rpcs3_savestate_ui_contract_test.py',
    'build-utils/patch_rpcs3_build268_tunnel.py',
    'lib/services/local_jit_debugger_lease.dart',
    'test/local_jit_debugger_lease_test.dart',
    'test/rpcs3_build268_tunnel_test.py',
    'test/rpcs3_jit_handshake_test.py',
}
changed = set(subprocess.check_output(
    ['git', 'diff', '--name-only', BASE, 'HEAD'], cwd=ROOT, text=True).splitlines())
if changed - ALLOWED:
    raise SystemExit('Refusing cached RPCS3: unexpected changed sources: ' + ', '.join(sorted(changed - ALLOWED)))
folder = Path(sys.argv[1])
ipas = list(folder.rglob('*.ipa'))
if len(ipas) != 1:
    raise SystemExit('Expected exactly one Build 266 reference IPA')
ipa = ipas[0]
if hashlib.sha256(ipa.read_bytes()).hexdigest() != IPA_SHA256:
    raise SystemExit('Build 266 reference IPA checksum mismatch')
with zipfile.ZipFile(ipa) as archive:
    data = archive.read('Payload/NeoStation.app/Frameworks/libRPCS3Core.dylib')
if hashlib.sha256(data).hexdigest() != CORE_SHA256:
    raise SystemExit('Verified RPCS3 core checksum mismatch')
for relative in ['build/rpcs3-embedded-core/libRPCS3Core.dylib',
                 'packages/rpcs3_internal_bridge/ios/Frameworks/libRPCS3Core.dylib']:
    target = ROOT / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    target.chmod(0o755)
report = ROOT / 'build/rpcs3-ci/rpcs3-core-provenance.json'
report.parent.mkdir(parents=True, exist_ok=True)
report.write_text(json.dumps({'sourceBuild': '266', 'sourceCommit': BASE,
    'sourceWorkflowRun': 35140629752, 'sourceIPA_SHA256': IPA_SHA256,
    'coreSHA256': CORE_SHA256, 'sourceChangeGatePassed': True,
    'changedPaths': sorted(changed)}, indent=2) + '\n')
print('Reused exact verified Build 266 RPCS3 binary; no emulation core source changes.')
