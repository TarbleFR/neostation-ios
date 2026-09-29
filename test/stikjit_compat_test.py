#!/usr/bin/env python3
"""Execute the production StikJIT selection and classic RSP transaction.

No device success is inferred: Swift tests use a controlled debugger transport.
The modern dispatch and DDI sources are also compared to the pinned upstream.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SOURCE = Path(sys.argv.pop(1)).resolve()
ROOT = Path(__file__).resolve().parents[1]


def original(name):
    return subprocess.check_output(['git', 'show', 'HEAD:' + name], cwd=SOURCE, text=True)


class CompatibilityTests(unittest.TestCase):
    def test_modern_dispatch_and_ddi_are_unchanged(self):
        for name in ('DDISession.swift', 'DeveloperDiskImageService.swift', 'ProcessInfo+TXM.swift',
                     'SynchronousDDIDownloader.swift'):
            self.assertEqual((SOURCE/'Sources'/name).read_text(), original('Sources/'+name))
        session = (SOURCE/'Sources/JITSession.swift').read_text()
        old = original('Sources/JITSession.swift')
        marker = '        switch (forceScript, txmPresence) {'
        self.assertEqual(session.split(marker)[1].split('    private func neoStationAttachClassic')[0],
                         old.split(marker)[1].split('    private func attachWithoutScript')[0])
        self.assertEqual(session.split('    private func attachWithoutScript')[1],
                         old.split('    private func attachWithoutScript')[1])
        for lower, cls in (('rpcs3','Rpcs3'),('armsx2','Armsx2')):
            helper=(ROOT/f'packages/{lower}_jit_helper/ios/Classes/{cls}JITRequestHandlerBase.swift').read_text()
            self.assertIn('neoStationClassicAttach: !requiresCoreHandshake',helper)
            self.assertIn('forceScript: requiresCoreHandshake',helper)
            self.assertIn('PropertyListSerialization.propertyList(',helper)
            self.assertIn('publicKey.count == 32',helper)
            self.assertIn('privateKey.count == 32',helper)
        other=(ROOT/'packages/dolphin_jit_helper/ios/Classes/DolphinJITRequestHandlerBase.swift').read_text()
        self.assertNotIn('neoStationClassicAttach:',other)

    def test_execute_actual_policy_and_classic_protocol(self):
        session=(SOURCE/'Sources/JITSession.swift').read_text()
        policy=session.split('    static func neoStationUsesClassicAttach',1)[1].split('    struct Tunnel',1)[0]
        policy='    static func neoStationUsesClassicAttach'+policy
        gate=session.split('        // NEOSTATION_STIKJIT_IOS18_CLASSIC_V1',1)[1]
        gate=gate.split('    private func neoStationAttachClassic',1)[0].rsplit('    }',1)[0]
        gate=gate.replace('ProcessInfo.processInfo.operatingSystemVersion.majorVersion','osMajor')
        method='    private func neoStationAttachClassic'+session.split('    private func neoStationAttachClassic',1)[1].split('    private func attachWithoutScript',1)[0]
        harness=r'''
import Foundation
enum TXMPresence { case present, absent, unknown }
enum StikJITError: Error { case scriptExecution(String), txmDetectionUnavailable }
enum StikJIT { enum Script { case universal } }
struct Configuration { var neoStationClassicAttach: Bool }
final class ScriptRunner {
    static var hits=0
    init(targetPID:Int32,debugProxy:OpaquePointer,script:StikJIT.Script,progress:(String)->Void) {}
    func run() throws { Self.hits += 1 }
}
final class Harness {
    var configuration=Configuration(neoStationClassicAttach:true)
    var commands=[String]()
    var replies:[String?]=["T05thread:1;","OK"]
    var upstreamAttachCount=0
    func sendCommand(_ command:String, over proxy:OpaquePointer) throws -> String? {
        commands.append(command)
        return replies.isEmpty ? nil : replies.removeFirst()
    }
    func attachWithoutScript(targetPID:Int32,debugProxy:OpaquePointer,progress:(String)->Void) throws {
        upstreamAttachCount += 1
    }
POLICY
METHOD
    func execute(osMajor:Int,forceScript:Bool,txmPresence:TXMPresence) throws {
        let targetPID:Int32=123
        let debugProxy=OpaquePointer(bitPattern:1)!
        let progress:(String)->Void={_ in}
        let script=StikJIT.Script.universal
GATE
    }
}
var cases=0
for os in [18, 26, 27] {
  for txm in [TXMPresence.present, .absent, .unknown] {
    for requested in [false,true] {
      for force in [false,true] {
        let h=Harness(); h.configuration.neoStationClassicAttach=requested
        ScriptRunner.hits=0
        let classic=requested && os<26 && !force
        do {
          try h.execute(osMajor:os,forceScript:force,txmPresence:txm)
          if classic {
            precondition(h.commands == ["vAttach;7b","D"] && ScriptRunner.hits==0)
          } else if force || txm == .present {
            precondition(ScriptRunner.hits==1 && h.commands.isEmpty)
          } else {
            precondition(txm == .absent && h.upstreamAttachCount==1)
          }
        } catch {
          precondition(!classic && !force && txm == .unknown)
        }
        cases += 1
      }
    }
  }
}
for response in ["T05thread:1;","S05"] {
  let h=Harness(); h.replies=[response,"OK"]
  try h.execute(osMajor:18,forceScript:false,txmPresence:.present)
  precondition(h.commands == ["vAttach;7b","D"]); cases += 1
}
for response:String? in [nil,"","E01","OK","Txx","S","W00"] {
  let h=Harness(); h.replies=[response,"OK"]
  var rejected=false
  do { try h.execute(osMajor:18,forceScript:false,txmPresence:.present) } catch { rejected=true }
  precondition(rejected && h.commands == ["vAttach;7b"]); cases += 1
}
for response:String? in [nil,"","E01"] {
  let h=Harness(); h.replies=["T05",response]
  var rejected=false
  do { try h.execute(osMajor:18,forceScript:false,txmPresence:.present) } catch { rejected=true }
  precondition(rejected && h.commands == ["vAttach;7b","D"]); cases += 1
}
print("PASS: \(cases) production Swift policy/RSP cases; iOS18/26/27, TXM present/absent/unknown, default/opt-in/force, attach/detach errors")
'''.replace('POLICY',policy).replace('METHOD',method).replace('GATE',gate)
        with tempfile.TemporaryDirectory() as tmp:
            swift=Path(tmp)/'main.swift'; executable=Path(tmp)/'compat-test'
            swift.write_text(harness)
            subprocess.run(['swiftc',str(swift),'-o',str(executable)],check=True)
            subprocess.run([str(executable)],check=True)


if __name__=='__main__':
    unittest.main()
