#!/usr/bin/env python3
"""Carry the donor's requested memory capabilities; device signing stays external."""
import plistlib
from pathlib import Path
from configure_neoswap_donor import REQUIRED_DONOR_ENTITLEMENTS
from embed_rpcs3_host_entitlements import ROOT, PRODUCTS, embed


def main() -> None:
    apps = list(PRODUCTS.glob('*.app'))
    if len(apps) != 1:
        raise SystemExit('Expected exactly one built NeoStation application')
    extension = apps[0] / 'PlugIns/NeoSwapDonor.appex'
    info = plistlib.loads((extension / 'Info.plist').read_bytes())
    embed(extension / info['CFBundleExecutable'], ROOT / 'ios/NeoSwapDonor/NeoSwapDonor.entitlements',
          required=REQUIRED_DONOR_ENTITLEMENTS, owner='NeoSwapDonor')
    print('Donor requested entitlements embedded; effective device profile and memory limit are not inferred.')


if __name__ == '__main__':
    main()
