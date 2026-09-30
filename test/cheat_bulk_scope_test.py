from pathlib import Path
import json
import hashlib
import re
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='4ce8c7fb7dedf8481a072d1a4acdffb9f275d120'
allowed=set()
for package,editor in [('dolphin_internal_bridge','DOLManualCheatEditor'),('armsx2_internal_bridge','ARMSX2ManualCheatEditor')]:
    base=f'packages/{package}/ios/Classes/'
    allowed.update(base+name for name in ('NeoCheatParser.h','NeoCheatDocument.h','NeoCheatStore.h','NeoCheatLabels.h',editor+'.h'))
    allowed.add(base+('DolphinSessionMenu.mm' if package.startswith('dolphin') else 'Armsx2SessionMenu.mm'))
    for name in ('NeoCheatParser.h','NeoCheatDocument.h','NeoCheatStore.h','NeoCheatLabels.h'):
        assert (ROOT/base/name).read_text()==(ROOT/'native/cheats'/name).read_text()
    assert (ROOT/base/(editor+'.h')).read_text()==(ROOT/'native/cheats/NeoManualCheatEditor.template.h').read_text().replace('NEO_EDITOR_CLASS',editor)
# Audit the completed bulk-cheat feature against its own immutable endpoint.
# Subsequent NeoSwap runtime changes have a separate strict scope test; they
# must not masquerade as cheat changes or alter any of the accepted cheat code.
FEATURE_END='f4583c6a3083b8aed358da28b2f8f849256e0e8b'
changed=subprocess.check_output(['git','diff','--name-only',BASE,FEATURE_END,'--','packages','lib','native','build-utils'],cwd=ROOT,text=True).splitlines()
import runpy
candidate=runpy.run_path(str(ROOT/'test/import_memory_candidate_scope_test.py'))
RETAINED_END='3ccde925351b3e59985ba466e013e87a857d6ad0'
# These inherited localization/menu corrections predate this candidate. Keep
# their exact accepted endpoint separate from the original bulk feature audit.
RETAINED_SHA256={
    'native/cheats/NeoCheatLabels.h': 'e9cef1b8b91ed7c6f74eb976de05c6992c94c7c7e7796690455bfff86a532c1a',
    'native/cheats/NeoManualCheatEditor.template.h': '0efd4176f898426275fa8508da34999eb1895b3ad3e45ec39f3b057c873854de',
    'native/cheats/bulk-labels.json': '31e85457ba0ff7b35b58672649dff4f322982800caacf19cf6f82c87bd9ca708',
    'packages/armsx2_internal_bridge/ios/Classes/ARMSX2ManualCheatEditor.h': 'e41f07101422009d9060550a836c19275a040bdd0d4ab83aab44ce2a1f32f194',
    'packages/armsx2_internal_bridge/ios/Classes/Armsx2SessionMenu.mm': 'f5c9cf4df19cd14902a8afdd1719bcbbe2a8df4cc9e9b61a7443e3fdd19b6104',
    'packages/armsx2_internal_bridge/ios/Classes/NeoCheatLabels.h': 'e9cef1b8b91ed7c6f74eb976de05c6992c94c7c7e7796690455bfff86a532c1a',
    'packages/dolphin_internal_bridge/ios/Classes/DOLManualCheatEditor.h': '4d0bb5260fb8f70d0dc8e16320e610a691a5f67f395988035232d8045913759a',
    'packages/dolphin_internal_bridge/ios/Classes/DolphinSessionMenu.mm': '9b253bc23602a47033459c0e5dc2ba4d06b05cdf525f7472c6d572a26a6b9400',
    'packages/dolphin_internal_bridge/ios/Classes/NeoCheatLabels.h': 'e9cef1b8b91ed7c6f74eb976de05c6992c94c7c7e7796690455bfff86a532c1a',
}
retained=subprocess.check_output(['git','diff','--name-only',FEATURE_END,RETAINED_END,'--','native/cheats',*sorted(allowed)],cwd=ROOT,text=True).splitlines()
assert set(retained)==set(RETAINED_SHA256), 'Inherited cheat scope changed'
for path,expected in RETAINED_SHA256.items():
    original=subprocess.check_output(['git','show',RETAINED_END+':'+path],cwd=ROOT)
    assert hashlib.sha256(original).hexdigest()==expected, 'Inherited endpoint changed: '+path
    if path not in candidate['approved']:
        assert (ROOT/path).read_bytes()==original, 'Unaudited inherited cheat change: '+path
current=subprocess.check_output(['git','diff','--name-only',RETAINED_END,'--','native/cheats',*sorted(allowed)],cwd=ROOT,text=True).splitlines()
assert not set(current)-candidate['approved'],set(current)-candidate['approved']
for path in changed:
    assert path in allowed or path.startswith('native/cheats/') or path in (
        'build-utils/private-test-365-recipient.pem','build-utils/validate_cheat_bulk_ipa.py'), 'Out-of-scope runtime change: '+path
# Existing single-code parser, JIT state machines, core sources and loaders are identical.
p='native/cheats/NeoCheatParser.h'
assert (ROOT/p).read_text()==subprocess.check_output(['git','show',BASE+':'+p],cwd=ROOT,text=True)
labels=json.loads((ROOT/'native/cheats/bulk-labels.json').read_text())
assert set(labels)=={'en','fr','de','es','it','pt','ru','id','ja','ko','zh','zh_Hant'}
header=(ROOT/'native/cheats/NeoCheatLabels.h').read_text()
for language,values in labels.items():
    assert set(values)==set(labels['en']) and all(values.values()),language
    for key,value in values.items():
        assert value in header,(language,key)
        assert set(re.findall(r'\{\w+\}',value))==set(re.findall(r'\{\w+\}',labels['en'][key])),(language,key)
for package in ('dolphin_internal_bridge','armsx2_internal_bridge'):
    menu=ROOT/f'packages/{package}/ios/Classes'/('DolphinSessionMenu.mm' if package.startswith('dolphin') else 'Armsx2SessionMenu.mm')
    assert 'cheatImportFromMenu' in menu.read_text()
print('PASS: immutable bulk-import endpoint; separately audited requested import UI delta; exact generated editors and12 locales')
