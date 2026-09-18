#!/usr/bin/env python3
"""Verify IPA270 transport changes with the exact Build 269 runtime scripts.

Tests of an inactive experimental resource do not authorize selecting it in the
production helper. Binary/package checks do not establish iPhone runtime success.
"""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from validate_build269_identity import verify as verify269
from patch_rpcs3_stop_reply270 import protocol_script, BASELINE_MARKER

UNIVERSAL_269_SHA256 = '22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1'
LEGACY_269_SHA256 = '787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec'


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
        helper_data = [archive.read(name) for name in helpers]
        assert any(b'RPCS3-JIT-last.json' in data and b'previous_helper_log' in data
                   for data in helper_data), 'Durable helper journal missing'
        assert any(BASELINE_MARKER.encode() in data for data in helper_data), 'Baseline RPCS3 script selection missing'
        assert all(b'NEOSTATION_RPCS3_STOP_REPLY_270: dedicated protocol selected.' not in data
                   for data in helper_data), 'Experimental runtime script selection must be absent'
        script_root = prefix + 'Frameworks/StikJIT.framework/'
        original = archive.read(script_root + 'universal.js')
        legacy = archive.read(script_root + 'legacy.js')
        assert hashlib.sha256(original).hexdigest() == UNIVERSAL_269_SHA256, 'RPCS3 must use the exact pre-hotfix 269 script'
        assert hashlib.sha256(legacy).hexdigest() == LEGACY_269_SHA256, 'Dolphin script changed unexpectedly'
        experimental_name = script_root + 'rpcs3-universal.js'
        experimental_hash = None
        if experimental_name in archive.namelist():
            inactive = archive.read(experimental_name)
            assert inactive.decode('utf-8') == protocol_script(original.decode('utf-8'))
            experimental_hash = hashlib.sha256(inactive).hexdigest()
    helper_source = (Path(__file__).resolve().parents[1] /
                    'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift').read_text()
    assert 'script: .universal,' in helper_source
    assert 'script: selectedScript,' not in helper_source and '.custom(scriptURL)' not in helper_source
    report.update({'build270TransportVerified': True,
                   'nativeIdentity': 'NEOSTATION_RPCSS3_TRANSPORT_270',
                   'rpcs3BridgeBinary': host_path, 'helperJournalBinaries': helpers,
                   'runtimeRPCS3Script': 'universal.js (exact Build 269 baseline)',
                   'experimentalStopReplyScriptSelected': False,
                   'inactiveExperimentalResourceSHA256': experimental_hash,
                   'originalUniversalSHA256': hashlib.sha256(original).hexdigest(),
                   'originalLegacySHA256': hashlib.sha256(legacy).hexdigest(),
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
