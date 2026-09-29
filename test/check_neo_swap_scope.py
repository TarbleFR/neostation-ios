"""Freeze non-swap runtimes and prove that the single RPCS3 delta is scoped."""
from pathlib import Path
import hashlib, json, subprocess
ROOT=Path(__file__).resolve().parents[1]
import runpy
candidate=runpy.run_path(str(ROOT/'test/import_memory_candidate_scope_test.py'))
BASE='f4583c6a3083b8aed358da28b2f8f849256e0e8b'
def original(p):
    return subprocess.check_output(['git','show',BASE+':'+p],cwd=ROOT,text=True)
allowed={
 'build-utils/build_rpcs3_embedded_core.sh','build-utils/rpcs3/canonical-source.json',
 'build-utils/rpcs3/embedded-core.patch','build-utils/private-test-366-recipient.pem',
 'build-utils/validate_neoswap_ipa.py',
 'native/neoswap/NeoSwapClient.h','native/neoswap/localizations.json',
 'lib/l10n/neoswap_locale.dart','lib/screens/settings_screen/neoswap_dialog.dart',
 'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart',
 'packages/neo_swap/pubspec.yaml','packages/neo_swap/lib/neo_swap.dart',
 'packages/neo_swap/ios/neo_swap.podspec','packages/neo_swap/ios/Classes/NeoSwap.cpp',
 'packages/neo_swap/ios/Classes/NeoSwap.h','packages/neo_swap/ios/Classes/NeoSwapPlugin.h',
 'packages/neo_swap/ios/Classes/NeoSwapPlugin.mm',
 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm',
 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3PerformanceOverlay.mm',
 'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec',
}
changed=subprocess.check_output(['git','diff','--name-only',BASE,'--','packages','lib','native','build-utils'],cwd=ROOT,text=True).splitlines()
assert not set(changed)-allowed-candidate['approved']-{'native/import-memory-candidate.json'}, set(changed)-allowed-candidate['approved']
old=json.loads(original('build-utils/rpcs3/canonical-source.json'))
new=json.loads((ROOT/'build-utils/rpcs3/canonical-source.json').read_text())
core_changes={'rpcs3/ios/RPCS3IOS.cpp','rpcs3/ios/RPCS3IOS.exports'}
new_files={'rpcs3/ios/NeoSwap.h','rpcs3/ios/NeoSwapClient.h','rpcs3/Emu/RSX/Common/aligned_malloc.hpp'}
assert set(new['files_sha256']) == set(old['files_sha256']) | new_files
for p,h in old['files_sha256'].items():
    if p not in core_changes: assert new['files_sha256'][p]==h, 'Unrelated Core source: '+p
assert new['upstream_commit']==old['upstream_commit']
assert new['llvm_aarch64_ghc_patch']==old['llvm_aarch64_ghc_patch']
assert new['device_runtime_tested'] is False
patch=(ROOT/'build-utils/rpcs3/embedded-core.patch').read_bytes()
assert hashlib.sha256(patch).hexdigest()==new['patch_sha256']
for src,dst in [('packages/neo_swap/ios/Classes/NeoSwap.h','rpcs3/ios/NeoSwap.h'),('native/neoswap/NeoSwapClient.h','rpcs3/ios/NeoSwapClient.h')]:
    data=(ROOT/src).read_bytes().replace(b'\r\n',b'\n')
    assert hashlib.sha256(data).hexdigest()==new['files_sha256'][dst], 'ABI/client drift: '+src
host=(ROOT/'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm').read_text()
assert host.index('rpcs3_ios_set_neoswap_api')<host.index('self->_api.initialize(&options)')
assert 'NeoSwap_RegisterClient(NEOSWAP_RPCS3)' in host
assert (ROOT/'packages/neo_swap/ios/Classes/NeoSwap.cpp').read_text().count('struct Broker {')==1
locales=json.loads((ROOT/'native/neoswap/localizations.json').read_text())
assert set(locales)=={'en','es','ru','zh','zh_Hant','pt','fr','de','it','id','ja','ko'}
print('PASS NeoSwap scope: all-title RPCS3 RSX CPU adapter; JIT/VM/GPU and other cores unchanged; one host broker; ABI hashes locked')
