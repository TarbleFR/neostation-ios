#!/usr/bin/env python3
"""Embed exact donor and page-relay requests; device signing stays external."""
import plistlib
from pathlib import Path
from configure_neoswap_donor import DONOR_CONTRACTS, REQUIRED_DONOR_ENTITLEMENTS
from configure_neoswap_relay import RELAY_CONTRACTS, REQUIRED_RELAY_ENTITLEMENTS
from embed_rpcs3_host_entitlements import ROOT, PRODUCTS, embed


def main() -> None:
    apps = list(PRODUCTS.glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('Expected exactly one built NeoStation application')
    for bundle, contract in DONOR_CONTRACTS.items():
        extension = apps[0] / 'PlugIns' / bundle
        info = plistlib.loads((extension / 'Info.plist').read_bytes())
        if info.get('NeoStationNeoSwapDonorIndex') != contract['index']:
            raise SystemExit('Unexpected donor index: ' + bundle)
        embed(extension / info['CFBundleExecutable'],
              ROOT / 'ios' / Path(bundle).stem / 'NeoSwapDonor.entitlements',
              required=REQUIRED_DONOR_ENTITLEMENTS, owner=Path(bundle).stem)
    host_info = plistlib.loads((apps[0] / 'Info.plist').read_bytes())
    for bundle, contract in RELAY_CONTRACTS.items():
        extension = apps[0] / 'PlugIns' / bundle
        info = plistlib.loads((extension / 'Info.plist').read_bytes())
        name = Path(bundle).stem
        if (info.get('CFBundleIdentifier') != host_info['CFBundleIdentifier'] + contract['bundleSuffix']
                or info.get('CFBundleExecutable') != name
                or info.get(contract['marker']) != '1'
                or info.get('NSExtension', {}).get('NSExtensionPrincipalClass') != contract['principalClass']):
            raise SystemExit('Unexpected page-relay identity: ' + bundle)
        embed(extension / name, ROOT / 'ios' / name / 'NeoSwapPageRelay.entitlements',
              required=REQUIRED_RELAY_ENTITLEMENTS, owner=name)
    print('Donor and relay requested entitlements embedded; effective device profiles and memory limits are not inferred.')


if __name__ == '__main__':
    main()
