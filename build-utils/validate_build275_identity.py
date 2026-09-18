#!/usr/bin/env python3
"""Inspect Build 275 VPN-persistence IPA; packaging success is not iPhone validation."""
from pathlib import Path
import argparse,hashlib,json,plistlib,zipfile

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
  assert str(info['CFBundleVersion'])=='275','Wrong application build'
  assert info.get('UIFileSharingEnabled') is True,'Documents must remain visible in Files'
  checked={}
  for name,expected in BASELINE.items():
   digest=hashlib.sha256(archive.read(prefix+name)).hexdigest()
   assert digest==expected,'VPN-only build changed known-good runtime: '+name
   checked[name]=digest
  assert prefix+'Frameworks/StikJIT.framework/rpcs3-universal.js' not in archive.namelist()

  manager=archive.read(prefix+'Frameworks/stikjit_bridge.framework/stikjit_bridge')
  for marker in (
   b'NEOSTATION_VPN_STABLE_PREFLIGHT_274: initial route unavailable; VPN unchanged',
   b'NEOSTATION_VPN_STABLE_PREFLIGHT_274: route stable; VPN frozen for RPCS3 boot',
   b'NEOSTATION_VPN_STABLE_PREFLIGHT_274: route changed during preflight; VPN unchanged',
   b'Diagnostic-VPN-RPCS3.txt',
   b'Diagnostic-VPN-RPCS3-precedent.txt',
  ):
   assert marker in manager,'Missing compiled VPN policy marker: '+repr(marker)
  assert b'nativeDebuggerLease270=active' not in manager
  assert b'stage=status.load-preferences' in manager,'Manual/status preferences path unexpectedly missing'

  provider=archive.read(prefix+'PlugIns/NeoStationLocalTunnel.appex/NeoStationLocalTunnel')
  assert b'neostation.vpn271.packets' in provider,'Retain validated packet transport'
  assert b'network settings callback missing after 10s' in provider,'Manual start remains bounded'
  assert b'heartbeat expired' not in provider,'Host lifecycle must not terminate tunnel'
  assert b'packet write failed after bounded retries' not in provider,'Transient packet writes must not terminate the VPN'

  dolphin=archive.read(prefix+'Frameworks/dolphin_internal_bridge.framework/dolphin_internal_bridge')
  assert b'DolphinRetroAchievementsAccount' in dolphin,'Dolphin RA account flow changed'

  # rpcs3_jit_helper is a CocoaPods static framework. Its Swift implementation
  # is linked into RPCS3JITHelper.appex and must not be emitted as a duplicate
  # runtime framework under NeoStation.app/Frameworks.
  dynamic_helper=prefix+'Frameworks/rpcs3_jit_helper.framework/rpcs3_jit_helper'
  assert dynamic_helper not in archive.namelist(),'RPCS3 static helper unexpectedly packaged as a dynamic framework'
  helper=archive.read(prefix+'PlugIns/RPCS3JITHelper.appex/RPCS3JITHelper')
  assert b'NEOSTATION_RPCS3_STOP_REPLY_270' not in helper,'Abandoned JIT transport code returned'

  internal=archive.read(prefix+'Frameworks/rpcs3_internal_bridge.framework/rpcs3_internal_bridge')
  assert b'RPCS3 virtual memory layout validated and cached for this process.' in internal,'Build 274 cached memory preflight missing'
  assert b'com.neogamelab.neostation.rpcs3.diagnostics' in internal,'Build 274 async diagnostic queue missing'

  dart=archive.read(prefix+'Frameworks/App.framework/App')
  assert b'Diagnostic-VPN-RPCS3.txt' in dart,'VPN diagnostic file reference missing'
  assert b'The selected VPN route is unavailable.' in dart,'Manual-only route error missing'
  assert b'RPCS3 JIT did not remain active after the initial StikJIT attach.' in dart,'Build 274 single-attach Dart path missing'

  return {
   'build':275,
   'baselineBuild':274,
   'unchangedBaselineSHA256':checked,
   'vpnPolicy':'manual ON/OFF only; persistent provider; one stable route gate before JIT; no VPN mutation during RPCS3 boot',
   'onDemand':False,
   'diagnosticFile':'Documents/Diagnostic-VPN-RPCS3.txt',
   'diagnosticPreviousFile':'Documents/Diagnostic-VPN-RPCS3-precedent.txt',
   'dolphinAccountPreserved':True,
   'newJITProtocol':False,
   'rpcS3OptimizationChanges':False,
   'ipaSHA256':hashlib.sha256(path.read_bytes()).hexdigest(),
   'deviceTested':False,
  }

if __name__=='__main__':
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('ipa',type=Path)
 parser.add_argument('--report',type=Path,required=True)
 args=parser.parse_args()
 result=verify(args.ipa)
 args.report.write_text(json.dumps(result,indent=2)+'\n')
 print(json.dumps(result,indent=2))
