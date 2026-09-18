#!/usr/bin/env python3
"""Verify actual sources, not labels: no new JIT protocol ships in Build 271."""
from pathlib import Path
import hashlib
import json
import subprocess

ROOT=Path(__file__).resolve().parents[1]
BASE='e653c5711d5fc139b066bb8c120e4874e4cf61c5'
FILES=[
 'lib/services/rpcs3_internal_service.dart',
 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm',
 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h',
 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift',
 'build-utils/patch_stikjit_rpcs3.py',
 'build-utils/patch_stikjit_remote_pairing.py',
]

def main():
 result={}
 for name in FILES:
  baseline=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
  actual=(ROOT/name).read_bytes()
  if actual != baseline: raise AssertionError('RPCS3 267 baseline changed: '+name)
  result[name]=hashlib.sha256(actual).hexdigest()
 workflow=(ROOT/'.github/workflows/build-ipa-once.yml').read_text()
 assert 'patch_rpcs3_build270_transport.py' not in workflow
 assert 'patch_rpcs3_stop_reply270.py' not in workflow
 helper=(ROOT/FILES[3]).read_text()
 assert 'script: .universal' in helper and 'selectedScript' not in helper
 ui=(ROOT/'lib/screens/settings_screen/new_settings_options/tools_settings_content.dart').read_text()
 toggle=ui.split('Future<void> _toggleTunnel()',1)[1].split('Future<void> _refreshPairingState()',1)[0]
 assert 'await LocalJitTunnelService.status()' not in toggle
 assert 'request != _tunnelRequestId' in toggle
 assert 'request == _tunnelRequestId' in toggle
 assert 'final disable = _isUpdatingTunnel ||' in toggle
 manager=(ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift').read_text()
 provider=(ROOT/'native/local_jit_tunnel/PacketTunnelProvider.swift').read_text()
 assert 'beginDebuggerLease' not in manager and 'startHeartbeat' not in manager
 assert 'expireHeartbeat' not in provider and 'jitLeaseBegin' not in provider
 assert 'seconds: 30' in manager and 'seconds: 10' in manager
 assert 'limit=4s' in manager and 'no native callback' in manager
 journal=(ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationVPNDiagnostics.swift').read_text()
 assert 'Diagnostic-VPN-RPCS3.txt' in journal and 'snapshotRPCS3' in journal
 assert 'NeoStationVPNDiagnostics.initialize()' in (ROOT/'packages/stikjit_bridge/ios/Classes/StikjitBridgePlugin.swift').read_text()
 report={'referenceBuild':267,'referenceCommit':BASE,'sourceSHA256':result,'newJITProtocol':False,'deviceTested':False}
 output=ROOT/'build/rpcs3-ci/build271-source-baseline.json'
 output.parent.mkdir(parents=True,exist_ok=True)
 output.write_text(json.dumps(report,indent=2)+'\n')
 print('PASS: exact Build 267 RPCS3 launch/helper/JIT script patch sources; bounded VPN-only changes and TXT diagnostics')

if __name__=='__main__': main()
