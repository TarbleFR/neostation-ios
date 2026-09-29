"""Require the exact NeoSwap Core; keep the previous release's pin independent."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
CORE='a30a443723dc144ed5429e8ca23849ec746c396a'
workflow=(ROOT/'.github/workflows/neoswap-ipa.yml').read_text()
for token in (
    'RPCS3_CORE_HOST_SHA: '+CORE,
    "RPCS3_CORE_RUN_ID: '36619968561'",
    "assert identity['neoswap_client_abi'] == 1",
    'test/rpcs3_build352_gow3_memory_test.py',
    'test/check_neo_swap_scope.py',
    'build-utils/validate_neoswap_ipa.py',
    "'neoswap-check.yml'",
    'private-test-367-recipient.pem',
):
    assert token in workflow,token
assert 'contents: write' not in workflow and 'gh release create' not in workflow
for relative in ('build-utils/build_rpcs3_embedded_core.sh',
                 'build-utils/rpcs3/canonical-source.json',
                 'build-utils/rpcs3/embedded-core.patch',
                 '.github/workflows/rpcs3-core.yml',
                 'packages/neo_swap/ios/Classes/NeoSwap.h',
                 'packages/neo_swap/ios/Classes/NeoSwap.cpp',
                 'native/neoswap/NeoSwapClient.h',
                 'test/neoswap_test.cpp','test/neoswap_rpcs3_allocator_test.cpp'):
    old=subprocess.check_output(['git','show',CORE+':'+relative],cwd=ROOT)
    if relative=='packages/neo_swap/ios/Classes/NeoSwap.cpp':
        old=old.replace(b'c->capacity_bytes > 4 * 1024 * MiB',b'c->capacity_bytes > 8 * 1024 * MiB')
    assert old.replace(b'\r\n',b'\n')==(ROOT/relative).read_bytes().replace(b'\r\n',b'\n'),relative
print('PASS: exact NeoSwap core pin, unchanged core/ABI/recipe; explicitly audited8GiB host budget; private-only validation')
