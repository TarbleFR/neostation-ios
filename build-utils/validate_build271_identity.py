#!/usr/bin/env python3
"""Inspect the final IPA; package validation does not establish iPhone success."""
from pathlib import Path
import argparse, hashlib, json, plistlib, zipfile

BASELINE={
 'Frameworks/libRPCS3Core.dylib':'dba1bb3bf8847faf3e378c1815ffe895521d8d6404e468bb6a2eee5fa8cb4ddd',
 'Frameworks/DolphinCore.framework/DolphinCore':'60012e203c927d468cb6d82d21aa8f8e14299fedbf0b2f80ce0ea982d4e173ee',
 'Frameworks/StikJIT.framework/universal.js':'22b0146b14ac230b3e04f1cbcaadbfddd898cbe6bb96c554981bef9cff311ba1',
 'Frameworks/StikJIT.framework/legacy.js':'787df4678ca17fd100a1d002203bfac8771fae062175aa510da8d6af9f8167ec',
}

def verify(path):
 with zipfile.ZipFile(path) as archive:
  prefix='Payload/NeoStation.app/'
  info=plistlib.loads(archive.read(prefix+'Info.plist'))
  assert str(info['CFBundleVersion'])=='271', 'Wrong application build'
  assert info.get('UIFileSharingEnabled') is True, 'Documents must be visible in Files'
  checked={}
  for name,expected in BASELINE.items():
   digest=hashlib.sha256(archive.read(prefix+name)).hexdigest()
   assert digest==expected, 'Baseline 267 runtime changed: '+name
   checked[name]=digest
  assert prefix+'Frameworks/StikJIT.framework/rpcs3-universal.js' not in archive.namelist(), 'Do not ship the abandoned experimental JIT script'
  manager=archive.read(prefix+'Frameworks/stikjit_bridge.framework/stikjit_bridge')
  for marker in [b'Diagnostic-VPN-RPCS3.txt',b'Diagnostic-VPN-RPCS3-precedent.txt',b'stage=status.load-preferences',b'activate-owned',b'verify.remote-pairing-tcp']:
   assert marker in manager, 'Missing VPN or report implementation: '+repr(marker)
  assert b'nativeDebuggerLease270=active' not in manager, 'Abandoned debugger lease remains'
  provider=archive.read(prefix+'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
  assert b'neostation.vpn271.packets' in provider
  assert b'network settings callback missing after 10s' in provider
  assert b'heartbeat expired' not in provider, 'Host heartbeat must not terminate RPCS3 transport'
  dolphin=archive.read(prefix+'Frameworks/dolphin_internal_bridge.framework/dolphin_internal_bridge')
  assert b'DolphinRetroAchievementsAccount' in dolphin, 'Keep the approved account flow'
  helper=archive.read(prefix+'Frameworks/rpcs3_jit_helper.framework/rpcs3_jit_helper')
  assert b'NEOSTATION_RPCS3_STOP_REPLY_270' not in helper
  dart=archive.read(prefix+'Frameworks/App.framework/App')
  assert b'Diagnostic-VPN-RPCS3.txt' in dart, 'Missing frontend timeout/report information'
  return {'build':271,'baselineBuild':267,'unchangedBaselineSHA256':checked,
          'vpnControl':'bounded commands; explicit OFF; no host heartbeat dependency',
          'diagnosticFile':'Documents/Diagnostic-VPN-RPCS3.txt',
          'diagnosticPreviousFile':'Documents/Diagnostic-VPN-RPCS3-precedent.txt',
          'dolphinAccountPreserved':True,'newJITProtocol':False,
          'ipaSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),'deviceTested':False}

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('ipa',type=Path);parser.add_argument('--report',type=Path,required=True)
 args=parser.parse_args();result=verify(args.ipa)
 args.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
