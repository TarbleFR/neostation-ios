#!/usr/bin/env python3
"""Require old fixes AND both halves of the new activation path in final IPA."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile
from validate_build266_identity import validate, LEASE_PROVIDER_MARKERS

CORE = 'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd'


def verify(path):
    report = validate(path, '269')
    assert report['coreSHA256'] == CORE, 'RPCS3 core must remain byte-identical'
    assert report['dolphinAccountBinary'], 'Keep the approved Dolphin account fix'
    assert report['debuggerLeaseBinary'], 'Keep the Build 268 debugger protection'
    with zipfile.ZipFile(path) as archive:
        prefix = 'Payload/NeoStation.app/'
        provider = archive.read(prefix + 'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
        assert all(marker in provider for marker in LEASE_PROVIDER_MARKERS)
        assert b'Build 269: waiting for the first host heartbeat before the normal watchdog.' in provider
        manager = archive.read(report['managerBinary'])
        for marker in (b'activateOwnedTunnel', b'recovery=stop-reload-start; firstFailure=',
                       b'previous session did not stop; status='):
            assert marker in manager, f'Missing optimized host marker: {marker}'
        dart = archive.read(prefix + 'Frameworks/App.framework/App')
        assert b'activateOwnedTunnel' in dart, 'Flutter must invoke explicit owned activation'
        assert b'lastErrorDetail' in dart, 'Flutter must retain diagnostic details'
    report.update({'build269ActivationVerified': True,
                   'ipaSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
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
