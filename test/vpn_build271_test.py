#!/usr/bin/env python3
"""Execute Build 271 production Swift with simulated iOS effects.

Only platform APIs, installed signing fixtures and clock durations are replaced.
No successful test claims a real-device VPN or RPCS3 integration result.
"""
from pathlib import Path
import sys, re, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'test'))
import local_jit_transport_behavior_test as old

HELPERS=old.MANAGER_TESTS.split('DispatchQueue.global().async {',1)[0]
HELPERS=HELPERS.replace('  func stopTestHeartbeat() { stopHeartbeat() }','')
SCENARIOS=r'''
DispatchQueue.global().async {
  let outsider = main { profile(false, .connected) }
  let externalManager = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([outsider], [true])
  main { TestPlatform.signingFailure = .signingMissing }
  let external = ResultBox()
  externalManager.ensureRunning(completion: external.record)
  wait("external", { external.results.count == 1 })
  main {
    require(external.success?["managedByNeoStation"] as? Bool == false, "existing external route preserved")
    require(TestPlatform.loads == 0 && outsider.saves == 0 && outsider.connection.stops == 0, "no preferences or cold stop for external")
  }
  let owned = main { profile(true, .disconnected) }
  let control = main { NeoStationLocalTunnelManager.makeForTest() }
  setup([owned, outsider], [true])
  let enabled = ResultBox()
  control.enableOwned(completion: enabled.record)
  wait("enable", { enabled.results.count == 1 })
  main {
    require(enabled.success?["managedByNeoStation"] as? Bool == true, "manual ON requires our provider")
    require(owned.connection.starts == 1 && outsider.connection.stops == 0, "start only owned")
    require(!owned.isOnDemandEnabled, "no automatic reactivation")
  }
  setup([owned, outsider], [true])
  let reuse = ResultBox()
  control.ensureRunning(completion: reuse.record)
  wait("reuse", { reuse.results.count == 1 })
  main { require(owned.saves == 1 && owned.connection.starts == 1, "healthy owned connection never restarted") }
  let off = ResultBox()
  control.disable(completion: off.record)
  wait("off", { off.results.count == 1 })
  main { require(off.success != nil && !owned.isEnabled, "OFF persists and settles"); require(outsider.saves == 0, "foreign profile untouched") }
  setup([owned], [])
  main { TestPlatform.holdLoads = true; TestPlatform.loadCallbacks=[] }
  let status = ResultBox()
  control.status(completion: status.record)
  wait("bounded status", { status.results.count == 1 })
  main {
    require(status.error?.code == "connection_timeout", "status has independent deadline")
    TestPlatform.loadCallbacks.forEach { $0([owned], nil) }
  }
  main {}; main { require(status.results.count == 1, "late status completes only once") }
  for point in ["load", "save", "reload"] {
    let subject = main { profile(true, .disconnected) }
    let manager = main { NeoStationLocalTunnelManager.makeForTest() }
    setup([subject], [])
    main { TestPlatform.holdLoads = point == "load"; subject.holdSaves = point == "save"; subject.holdReload = point == "reload" }
    let result = ResultBox()
    manager.enableOwned(completion: result.record)
    wait("missing " + point, { result.results.count == 1 })
    main {
      require(result.error?.code == "connection_timeout", "missing callback must fail: " + point)
      require(subject.connection.starts == 0, "no unverified start after missing " + point)
      TestPlatform.holdLoads = false
      TestPlatform.loadCallbacks.forEach { $0([subject], nil) }; TestPlatform.loadCallbacks=[]
      subject.saveCallbacks.forEach { $0(nil) }; subject.saveCallbacks=[]
      subject.reloadCallbacks.forEach { $0(nil) }; subject.reloadCallbacks=[]
    }
    main {}; main { require(result.results.count == 1 && subject.connection.starts == 0, "late callbacks cannot restart: " + point) }
  }
  let delayed = main { profile(true, .disconnected) }
  setup([delayed], [])
  main { delayed.holdSaves = true }
  let race = main { NeoStationLocalTunnelManager.makeForTest() }
  let oldOn=ResultBox(), stop=ResultBox(), newOn=ResultBox()
  race.enableOwned(completion: oldOn.record)
  wait("pending save", { delayed.saveCallbacks.count == 1 })
  main { delayed.holdSaves = false }
  race.disable(completion: stop.record)
  wait("priority OFF", { oldOn.results.count == 1 && stop.results.count == 1 })
  main { require(oldOn.error?.code == "cancelled" && stop.success != nil, "stop settles before old SAVE replies") }
  setup([delayed], [true])
  race.enableOwned(completion: newOn.record)
  wait("new ON", { newOn.results.count == 1 })
  main { delayed.saveCallbacks.forEach { $0(nil) }; delayed.saveCallbacks=[] }
  main {}; main {
    require(newOn.success != nil && delayed.connection.starts == 1, "old callback cannot touch newer activation")
    require(oldOn.results.count == 1 && stop.results.count == 1, "no double completions")
  }
  let parallelProfile = main { profile(true, .disconnected) }
  setup([parallelProfile], [true])
  main { parallelProfile.holdSaves=true }
  let parallel = main { NeoStationLocalTunnelManager.makeForTest() }
  let results=ResultBox()
  parallel.enableOwned(completion: results.record)
  wait("parallel pending", { parallelProfile.saveCallbacks.count == 1 })
  parallel.ensureRunning(completion: results.record)
  main {}; main { parallelProfile.saveCallbacks.forEach { $0(nil) } }
  wait("parallel complete", { results.results.count == 2 })
  main { require(parallelProfile.connection.starts == 1, "one start for all callers") }
  let refusing = main { profile(true, .disconnected) }
  setup([refusing], [])
  main { (refusing.connection as! NETunnelProviderSession).acknowledgeHeartbeat=false }
  let refuseManager=main { NeoStationLocalTunnelManager.makeForTest() }, refused=ResultBox()
  refuseManager.enableOwned(completion: refused.record)
  wait("missing provider", { refused.results.count == 1 })
  main { require(refused.error != nil, "TCP alone cannot prove an owned provider") }
  let broken=main { profile(true, .disconnected) }
  setup([broken], [])
  main {
    broken.connection.onStart={ connection in connection.status = .connecting
      DispatchQueue.main.asyncAfter(deadline:.now()+0.01) { connection.status = .disconnected }
    }
    broken.connection.disconnectError=NSError(domain:"ProviderLaunch",code:77)
  }
  let failManager=main { NeoStationLocalTunnelManager.makeForTest() }, failed=ResultBox(), readFailure=ResultBox()
  failManager.enableOwned(completion: failed.record)
  wait("native error", { failed.results.count == 1 })
  failManager.status(completion: readFailure.record)
  wait("read error", { readFailure.results.count == 1 })
  main { require((readFailure.success?["lastErrorDetail"] as? String)?.contains("ProviderLaunch(77)")==true,"native error retained") }
  let hanging=main { profile(true, .disconnected) }
  setup([hanging], [])
  main { hanging.connection.onStart={ $0.status = .connecting }; hanging.connection.holdError=true }
  let hangManager=main { NeoStationLocalTunnelManager.makeForTest() }, hung=ResultBox()
  hangManager.enableOwned(completion:hung.record)
  wait("bounded connect and disconnect error", { hung.results.count == 1 })
  main { require(hung.error != nil && hanging.connection.starts == 1, "no automatic 25+25s retry") }
  print("PASS: 271 manager external no-reset, owned-only start, reuse, missing load/save/reload/status, late callbacks, priority OFF, coalescing, provider proof, native error, finite connect")
  exit(0)
}
dispatchMain()
'''

PROVIDER_TESTS=r'''
extension PacketTunnelProvider { func flush() { queue.sync {} } }
func eventually(_ message: String, _ test: () -> Bool) {
  let deadline = ProcessInfo.processInfo.systemUptime + 2
  while !test() {
    require(ProcessInfo.processInfo.systemUptime < deadline, message)
    Thread.sleep(forTimeInterval: 0.005)
  }
}
let provider=PacketTunnelProvider()
var starts=0
provider.startTunnel(options:nil) { error in require(error == nil,"valid start"); starts += 1 }
provider.flush(); provider.settingsCallbacks[0](nil); provider.flush()
require(starts==1 && provider.packetFlow.readers.count==1,"one startup and reader")
var packet=Data(repeating:0,count:24)
packet[0]=0x45; packet[2]=0; packet[3]=24
packet.replaceSubrange(12..<16,with:[10,7,1,1]); packet.replaceSubrange(16..<20,with:[10,7,0,1])
packet[20]=0xab
for _ in 0..<20 {
  provider.packetFlow.readers.removeFirst()([packet],[NSNumber(value:AF_INET)])
  provider.flush()
}
require(provider.packetFlow.writes.count==20,"packets flow without host heartbeat or debugger lease")
let output=provider.packetFlow.writes[0][0]
require(Array(output[12..<16]) == [10,7,0,1] && Array(output[16..<20]) == [10,7,1,1],"IP reflection")
require(output[20]==0xab,"no payload changes")
var stats:[String:Any]=[:]
provider.handleAppMessage(Data("vpn271-status".utf8)) { bytes in stats=(try? JSONSerialization.jsonObject(with:bytes!)) as? [String:Any] ?? [:] }
provider.flush(); require(stats["version"] as? Int==271 && stats["writtenPackets"] as? Int==20,"diagnostic counters")
var stopped=0
provider.stopTunnel(with:.userInitiated) { stopped += 1 }
provider.flush()
provider.packetFlow.readers.removeFirst()([packet],[NSNumber(value:AF_INET)])
provider.flush(); require(stopped==1 && provider.packetFlow.writes.count==20,"no writes after stop")
let cancelled=PacketTunnelProvider(); var cancels=0
cancelled.startTunnel(options:nil) { if $0 != nil { cancels += 1 } }
cancelled.flush(); cancelled.stopTunnel(with:.userInitiated) {}; cancelled.flush()
cancelled.settingsCallbacks[0](nil); cancelled.flush()
require(cancels==1 && cancelled.packetFlow.readers.isEmpty,"late startup callback cannot revive tunnel")
let noCallback=PacketTunnelProvider(); var timedout=false
noCallback.startTunnel(options:nil) { timedout = $0 != nil }
noCallback.flush()
eventually("settings callback deadline settles") { noCallback.flush(); return timedout }
require(timedout,"provider network-settings callback bounded")
let dropped=PacketTunnelProvider()
dropped.startTunnel(options:nil) { _ in }; dropped.flush(); dropped.settingsCallbacks[0](nil); dropped.flush()
dropped.packetFlow.readers.removeFirst()([Data([1]),packet],[NSNumber(value:AF_INET)])
dropped.flush(); require(dropped.packetFlow.writes.isEmpty,"malformed and missing protocol packets dropped")
let full=PacketTunnelProvider()
full.packetFlow.accepts=false
full.startTunnel(options:nil) { _ in }; full.flush(); full.settingsCallbacks[0](nil); full.flush()
full.packetFlow.readers.removeFirst()([packet],[NSNumber(value:AF_INET)]); full.flush()
eventually("write retries settle") { full.flush(); return full.cancels == 1 }
require(full.cancels==1 && full.packetFlow.attempts==4,"failed writes have bounded retries")
print("PASS: 271 provider no host dependency, packet reflection, counters, manual stop, stale start, settings deadline, malformed input, bounded backpressure")
'''

def main():
 # Packaging runs git diff --check. Validate the generated file here too,
 # before spending time compiling the app; do not suppress whitespace errors.
 generated=ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
 payload=generated.read_bytes()
 assert payload.endswith(b'\n') and not payload.endswith(b'\n\n'), 'Generated VPN manager must have exactly one terminal newline'
 with tempfile.TemporaryDirectory(prefix='vpn271-whitespace-') as temporary:
  directory=Path(temporary)
  subprocess.run(['git','init','--quiet'],cwd=directory,check=True,capture_output=True)
  fixture=directory/'generated.swift'
  fixture.write_bytes(b'// Generated source baseline.\n')
  subprocess.run(['git','add','generated.swift'],cwd=directory,check=True,capture_output=True)
  command=['git','--no-pager','diff','--check','--','generated.swift']
  fixture.write_bytes(payload+b'\n')
  negative=subprocess.run(command,cwd=directory,capture_output=True,text=True)
  assert negative.returncode!=0 and 'new blank line at EOF' in negative.stdout, 'The packaging regression must fail the real Git gate'
  fixture.write_bytes(payload)
  check=subprocess.run(command,cwd=directory,capture_output=True,text=True)
  assert check.returncode==0, 'Generated VPN manager failed git diff --check:\n'+check.stdout+check.stderr
 print('PASS: 271 generated VPN source passes the actual Git whitespace gate')
 manager=(ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift').read_text()
 assert 'NEOSTATION_VPN_CONTROL_271' in manager
 manager=manager.replace('import Network\n','').replace('import NetworkExtension\n','')
 manager=old.replace_method(manager,'  private func providerBundleIdentifier()', '''  private func providerBundleIdentifier() -> String? { "test.neostation.localtunnel" }''')
 manager=old.replace_method(manager,'  private static func signingCapabilityFailure()', '''  private static func signingCapabilityFailure() -> NeoStationLocalTunnelError? { TestPlatform.signingFailure }''')
 manager=re.sub(r'(seconds: )(30|12|10|5|4)\b',lambda m:m[1]+str(float(m[2])*0.02),manager)
 manager=manager.replace('seconds: TimeInterval = 5','seconds: TimeInterval = 0.1')
 manager=re.sub(r'(\.now\(\) \+ |systemUptime \+ )(12|10|5|4|1.5|0.5|0.2)\b',lambda m:m[1]+str(float(m[2])*0.02),manager)
 manager=manager.replace('routeProbeTimeout: TimeInterval = 1.25','routeProbeTimeout: TimeInterval = 0.025')
 platform=old.PLATFORM
 platform=platform.replace('''    require(String(data: data, encoding: .utf8) == "heartbeat", "heartbeat payload")''','''    require(data == Data("vpn271-status".utf8), "diagnostic identity ping")''')
 platform=platform.replace('responseHandler?(acknowledgeHeartbeat ? Data("alive".utf8) : nil)', '''responseHandler?(acknowledgeHeartbeat ? try! JSONSerialization.data(withJSONObject:["version":271,"ready":true]) : nil)''')
 platform=platform.replace('''    completionHandler(TestPlatform.managers, nil)''','''    if TestPlatform.holdLoads { TestPlatform.loadCallbacks.append(completionHandler) }
    else { completionHandler(TestPlatform.managers, nil) }''')
 platform=platform.replace('  var holdSaves = false','  var holdSaves = false\n  var holdReload = false\n  var reloadCallbacks = [(Error?) -> Void]()')
 platform=platform.replace('func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { completionHandler(nil) }', 'func loadFromPreferences(completionHandler: @escaping (Error?) -> Void) { if holdReload { reloadCallbacks.append(completionHandler) } else { completionHandler(nil) } }')
 platform=platform.replace('  static var loads = 0','  static var loads = 0\n  static var holdLoads = false\n  static var loadCallbacks = [([NETunnelProviderManager]?, Error?) -> Void]()')
 platform+='\nenum NeoStationVPNDiagnostics { static func record(_ a:String,_ b:String) {}\n static func snapshotRPCS3() {} }\n'
 helpers=HELPERS.replace('TestPlatform.signingFailure = nil; TestPlatform.loads = 0','TestPlatform.signingFailure = nil; TestPlatform.loads = 0; TestPlatform.holdLoads = false; TestPlatform.loadCallbacks=[]')
 print(old.run_swift(platform+manager+helpers+SCENARIOS,'PASS: 271 manager'))
 provider=(ROOT/'native/local_jit_tunnel/PacketTunnelProvider.swift').read_text().replace('import NetworkExtension\n','')
 provider=provider.replace('.now() + 10','.now() + 0.04')
 pplatform=old.PROVIDER_PLATFORM.replace('  var writes = [[Data]]()', '  var writes = [[Data]]()\n  var accepts=true\n  var attempts=0')
 pplatform=pplatform.replace('func writePackets(_ packets: [Data], withProtocols: [NSNumber]) { writes.append(packets) }','func writePackets(_ packets: [Data], withProtocols: [NSNumber]) -> Bool { attempts += 1; if accepts { writes.append(packets) }; return accepts }')
 print(old.run_swift(pplatform+provider+PROVIDER_TESTS,'PASS: 271 provider'))
 diagnostics=(ROOT/'packages/stikjit_bridge/ios/Classes/NeoStationVPNDiagnostics.swift').read_text()
 with tempfile.TemporaryDirectory(prefix='vpn271-report-') as temp:
  diagnostics=old.replace_method(diagnostics,'  private static var documents:',f'  private static var documents: URL? {{ URL(fileURLWithPath:"{temp}") }}')
  tests=r'''
extension NeoStationVPNDiagnostics { static func flush() { queue.sync {} } }
NeoStationVPNDiagnostics.initialize()
NeoStationVPNDiagnostics.record("test","token=secret-token password=secret-pass /var/mobile/private/file https://example.invalid/?key=secret")
NeoStationVPNDiagnostics.flush()
let folder=URL(fileURLWithPath: "FOLDER")
let path=folder.appendingPathComponent("Diagnostic-VPN-RPCS3.txt")
var report=try String(contentsOf:path,encoding:.utf8)
precondition(report.contains("VPN/RPCS3") && report.contains("redacted"))
precondition(!report.contains("secret-token") && !report.contains("secret-pass") && !report.contains("/var/mobile/private"))
let entries=[["timestamp":1,"stage":"core_load_begin","message":"do-not-copy-this-secret"], ["timestamp":2,"stage":"core_log","message":"do-not-copy-this-either"]] as [[String:Any]]
let native=entries.map { String(data:try! JSONSerialization.data(withJSONObject:$0),encoding:.utf8)! }.joined(separator:"\n")
try native.write(to:folder.appendingPathComponent("RPCS3-diagnostic.log"),atomically:true,encoding:.utf8)
NeoStationVPNDiagnostics.snapshotRPCS3(); NeoStationVPNDiagnostics.flush()
report=try String(contentsOf:path,encoding:.utf8)
precondition(report.contains("core_load_begin") && !report.contains("do-not-copy-this"))
try Data(repeating:65,count:524300).write(to:path)
NeoStationVPNDiagnostics.record("rotation","new-session"); NeoStationVPNDiagnostics.flush()
precondition(FileManager.default.fileExists(atPath:folder.appendingPathComponent("Diagnostic-VPN-RPCS3-precedent.txt").path))
let rotated=try String(contentsOf:path,encoding:.utf8)
precondition(rotated.contains("new-session"))
print("PASS: 271 report creation, local path, redaction, milestone-only recovery and bounded rotation")
'''.replace('FOLDER',temp)
  print(old.run_swift(diagnostics+tests,'PASS: 271 report'))

if __name__=='__main__':main()
