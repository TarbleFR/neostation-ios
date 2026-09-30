#!/usr/bin/env python3
"""Carry the donor's requested memory capabilities; device signing stays external."""
import plistlib
from pathlib import Path
from configure_neoswap_donor import DONOR_CONTRACTS, REQUIRED_DONOR_ENTITLEMENTS
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
    print('Donor requested entitlements embedded; effective device profiles and memory limits are not inferred.')


if __name__ == '__main__':
    main()
