from pathlib import Path
import json
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
subprocess.run(['git','diff','--exit-code',FEATURE_END,'--','native/cheats',*sorted(allowed)],cwd=ROOT,check=True)
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
print('PASS: immutable bulk-import feature scope; current cheat sources unchanged from accepted feature endpoint; exact generated editors and 12 locales')
