#!/usr/bin/env python3
"""Prove the host JIT state machines were not refactored by the legacy patch."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='beed82be2a851d19c8cdada8d48b04da7f5f106c'

def original(p):
    return subprocess.check_output(['git','show',BASE+':'+p],cwd=ROOT,text=True)

for lower,cls in (('rpcs3','Rpcs3'),('armsx2','Armsx2')):
    p=f'packages/{lower}_internal_bridge/ios/Classes/{cls}JitBridgePlugin.mm'
    old=original(p); new=(ROOT/p).read_text()
    if lower=='armsx2':
        start=new.index('  // Export legacy startup evidence only;')
        end=new.index('\n}\nstatic void ARMSX2Milestone',start)
        log=new[start:end]
        assert 'majorVersion >= 26) return;' in log
        assert 'armsx2_jit_debug.log' in log and '524288' in log
        new=new[:start]+new[end:]
        new=new.replace('message ?: @"");\n\n}', 'message ?: @"");\n}',1)
    new=new.replace('          : [NSString stringWithFormat:@"JIT_PREPARATION_TIMEOUT: StikJIT did not complete preparation. Last stage: %@",\n              session.logs.lastObject ?: @"No helper stage received."];',
                    '          : @"StikJIT did not attach universal.js to NeoStation.";')
    assert old==new,p+' changed outside diagnostics'
p='packages/dolphin_internal_bridge/ci/verify_ipa.py'
new=(ROOT/p).read_text()
# The shared IPA now contains the NeoSwap donor. Normalize only its reviewed
# packaging contract; every original Dolphin/JIT check must remain byte-exact.
replacements = (
    ('import sys\n', ''),
    ("sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'build-utils'))\n"
     'from validate_single_ipa_distribution import (\n'
     '    DONOR_CONTRACTS, DONOR_EXTENSION_POINT, validate as validate_distribution,\n'
     ')\n\n', ''),
    ('    **DONOR_CONTRACTS,\n', ''),
    ('    validate_distribution(ipa)\n', ''),
    ('(DONOR_EXTENSION_POINT if bundle_name in DONOR_CONTRACTS else SHARE_EXTENSION_POINT)',
     'SHARE_EXTENSION_POINT'),
)
for added, previous in replacements:
    assert new.count(added)==1, 'Unexpected NeoSwap packaging delta: '+added
    new=new.replace(added, previous)
assert new.replace("== '1.9.0', 'Wrong StikJIT version'", "== '1.5.0', 'Wrong StikJIT version'")==original(p)
p='packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift'
assert (ROOT/p).read_text().replace('StikJIT 1.9.0','StikJIT 1.5.0')==original(p)
print('PASS: exact retained JIT host state machines; only timeout text/legacy log; Dolphin algorithm unchanged')
