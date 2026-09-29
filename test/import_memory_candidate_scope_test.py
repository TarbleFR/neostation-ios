"""Explicitly audit the requested import UI, texture host and8GiB capacity delta."""
from pathlib import Path
import hashlib,json,re,subprocess
ROOT=Path(__file__).resolve().parents[1]
manifest=json.loads((ROOT/'native/import-memory-candidate.json').read_text())
assert manifest['baseline']=='549f6ae2a84a0b79afcb61b8ea5fb593c76a89a3'
allowed={
 'build-utils/private-test-367-recipient.pem','build-utils/validate_cheat_bulk_ipa.py','build-utils/generate_import_labels.py',
 'native/cheats/NeoManualCheatEditor.template.h','native/cheats/NeoCheatLabels.h','native/cheats/bulk-labels.json',
 'native/dolphin_textures/labels.json','native/neoswap/localizations.json',
 'lib/l10n/neoswap_locale.dart','lib/screens/settings_screen/neoswap_dialog.dart',
 'packages/neo_swap/lib/neo_swap.dart','packages/neo_swap/ios/neo_swap.podspec',
 'packages/neo_swap/ios/Classes/NeoSwap.cpp','packages/neo_swap/ios/Classes/NeoSwapPlugin.mm',
 'packages/neo_swap/ios/Classes/NeoSwapCapacityProbe.h',
 'packages/dolphin_internal_bridge/ios/dolphin_internal_bridge.podspec',
}
for package,editor,menu in [('dolphin_internal_bridge','DOLManualCheatEditor','DolphinSessionMenu'),('armsx2_internal_bridge','ARMSX2ManualCheatEditor','Armsx2SessionMenu')]:
    base=f'packages/{package}/ios/Classes/'
    allowed.update(base+p for p in ('NeoCheatLabels.h',editor+'.h',menu+'.mm'))
base='packages/dolphin_internal_bridge/ios/Classes/'
allowed.update(base+p for p in ('DolphinSessionMenu.h','DolphinInternalBridgePlugin.mm','DOLTextureZip.h','DOLTextureStore.h','DOLTextureSettings.h','DOLTextureLabels.h'))
approved=set(manifest['files_sha256'])
assert approved==allowed,approved^allowed
for p,h in manifest['files_sha256'].items():assert hashlib.sha256((ROOT/p).read_bytes()).hexdigest()==h,p
changed=set(subprocess.check_output(['git','diff','--name-only',manifest['baseline'],'--','packages','lib','native','build-utils'],cwd=ROOT,text=True).splitlines())
assert not changed-approved-{'native/import-memory-candidate.json'},changed-approved
def before(p):return subprocess.check_output(['git','show',manifest['baseline']+':'+p],cwd=ROOT,text=True)
p='packages/neo_swap/ios/Classes/NeoSwap.cpp'
assert (ROOT/p).read_text()==before(p).replace('c->capacity_bytes > 4 * 1024 * MiB','c->capacity_bytes > 8 * 1024 * MiB'), 'Unexpected broker/ABI change'
p=base+'DolphinInternalBridgePlugin.mm';source=(ROOT/p).read_text().replace('#include "DOLTextureSettings.h"\n','')
start=source.index('      menu.openTextureSettings = ^{');end=source.index('      menu.readRecording = ',start)
assert source[:start]+source[end:]==before(p),'Unrelated Dolphin host change'
catalog=json.loads((ROOT/'native/dolphin_textures/labels.json').read_text())
assert set(catalog)=={'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'}
for lang,values in catalog.items():
    assert set(values)==set(catalog['en']) and all(values.values()),lang
    for k,v in values.items():assert set(re.findall(r'\{\w+\}',v))==set(re.findall(r'\{\w+\}',catalog['en'][k]))
print('PASS requested candidate: exact import/texture/8GiB files; immutable core ABIs, JIT and unrelated host code;12 complete locales')
