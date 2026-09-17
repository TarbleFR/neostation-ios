#!/usr/bin/env python3
"""Verify exact IPA270 and all retained 269/268/267 fixes, not runtime success."""
import argparse
import json
from pathlib import Path
import zipfile
from validate_build269_identity import verify as verify269


def verify(path):
    report = verify269(path, '270')
    with zipfile.ZipFile(path) as archive:
        prefix = 'Payload/NeoStation.app/'
        provider = archive.read(prefix + 'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
        assert b'com.neogamelab.neostation.localtunnel.packets270' in provider
        assert b'Build 270 packet transport could not write after bounded retries.' in provider
        manager = archive.read(report['managerBinary'])
        assert b'nativeDebuggerLease270=active' in manager, 'Native lease freeze missing'
        host_path = prefix + 'Frameworks/rpcs3_internal_bridge.framework/rpcs3_internal_bridge'
        host = archive.read(host_path)
        assert b'NEOSTATION_EARLY_LOADER_270' in host
        assert b'native=NEOSTATION_RPCSS3_TRANSPORT_270' in host
        assert b'RPCS3-core-load-stderr.log' in host
        assert b'jit_helper_' in host
        helpers = [name for name in archive.namelist()
                   if name.endswith('.framework/rpcs3_jit_helper') or
                   name.endswith('/RPCS3JITHelper.appex/RPCS3JITHelper')]
        assert helpers, 'RPCS3 helper framework missing'
        assert any(b'RPCS3-JIT-last.json' in archive.read(name) and
                   b'previous_helper_log' in archive.read(name) for name in helpers), 'Durable helper journal missing'
    report.update({'build270TransportVerified': True,
                   'nativeIdentity': 'NEOSTATION_RPCSS3_TRANSPORT_270',
                   'rpcs3BridgeBinary': host_path, 'helperJournalBinaries': helpers,
                   'deviceTested': False})
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.ipa)
    args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
