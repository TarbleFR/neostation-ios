#!/usr/bin/env python3
"""Execute production shake detection/lifecycle with a mocked sensor boundary.

The real CoreMotion/TouchController API is separately type-checked for iOS.
These tests do not claim that Mario Kart accepted a gesture on a real phone.
"""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
TOUCH=ROOT/'packages/dolphin_internal_bridge/ios/Classes/TouchController'
STUB=r'''
import Foundation
struct CMAcceleration { var x:Double;var y:Double;var z:Double }
struct CMDeviceMotion { var timestamp:Double;var userAcceleration:CMAcceleration }
final class CMMotionManager {
  static var last:CMMotionManager?
  var isDeviceMotionAvailable=true
  var deviceMotionUpdateInterval:Double=0
  var starts=0,stops=0
  var receiver:((CMDeviceMotion?,Error?)->Void)?
  init(){Self.last=self}
  func startDeviceMotionUpdates(to queue:OperationQueue,withHandler handler:@escaping(CMDeviceMotion?,Error?)->Void){starts+=1;receiver=handler}
  func stopDeviceMotionUpdates(){stops+=1}
  func send(_ strength:Double,age:Double=0){receiver?(CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime-age,userAcceleration:CMAcceleration(x:strength,y:0,z:0)),nil)}
}
'''
MAIN=r'''
import Foundation
var cases=0
func expect(_ value:Bool,_ label:String){precondition(value,label);cases+=1}
for mask in 0..<256 {
  let bits=(0..<8).map{mask & (1 << $0) != 0}
  let accepted=DolphinPhoneShakePolicy.acceptsInput(wii:bits[0],remoteLayout:bits[1],sessionRunning:bits[2],visible:bits[3],touchEnabled:bits[4],appActive:bits[5],physicalController:bits[6],enabled:bits[7])
  expect(accepted == (mask == 191),"lifecycle gate \(mask)")
}
expect(DolphinPhoneShakePolicy.shakeButtons == [132,133,134],"actual upstream shake controls")
expect(DolphinPhoneShakePolicy.touchPort==4,"first Wii touchscreen")
for axis in 0..<3 {
  var d=DolphinShakeDetector()
  var v=[Double](repeating:0,count:3);v[axis] = -1.1
  expect(d.sample(x:v[0],y:v[1],z:v[2],timestamp:0),"orientation independent axis")
  expect(!d.sample(x:v[0],y:v[1],z:v[2],timestamp:1),"continuous movement cannot auto-repeat")
  expect(!d.sample(x:0,y:0,z:0,timestamp:2),"rest rearms")
  expect(d.sample(x:v[0],y:v[1],z:v[2],timestamp:2.1),"next deliberate gesture")
}
var d=DolphinShakeDetector()
for v in [0.0,0.1,0.25,0.6,0.89] {expect(!d.sample(x:v,y:0,z:0,timestamp:0),"normal movement ignored")}
expect(d.sample(x:1.2,y:0,z:0,timestamp:1),"threshold")
expect(!d.sample(x:0,y:0,z:0,timestamp:1.01),"rearm during cooldown")
expect(!d.sample(x:1.2,y:0,z:0,timestamp:1.1),"cooldown")
expect(d.sample(x:1.2,y:0,z:0,timestamp:1.4),"cooldown elapsed")
for bad in [Double.nan,Double.infinity,-Double.infinity] {
 expect(!d.sample(x:bad,y:0,z:0,timestamp:2),"bad acceleration")
 expect(!d.sample(x:0,y:0,z:0,timestamp:bad),"bad timestamp")
}
expect(!d.sample(x:0,y:0,z:0,timestamp:0.5),"old samples ignored")
d.reset();expect(d.sample(x:1.2,y:0,z:0,timestamp:0),"fresh session")
var events=[Bool]()
var owner:DolphinPhoneShake?=DolphinPhoneShake{events.append($0)}
let sensor=CMMotionManager.last!
owner!.setActive(true);owner!.setActive(true)
expect(sensor.starts==1,"idempotent sensor start")
sensor.send(1.2,age:0.5);expect(events.isEmpty,"backlogged gesture discarded")
sensor.send(1.2);expect(events == [true],"one virtual shake press")
RunLoop.main.run(until:Date().addingTimeInterval(0.18))
expect(events == [true,false],"automatic release")
owner!.stop();let old=sensor.receiver
old?(CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime,userAcceleration:CMAcceleration(x:2,y:0,z:0)),nil)
expect(events == [true,false],"queued callbacks ignored after stop")
owner!.setActive(true)
old?(CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime,userAcceleration:CMAcceleration(x:2,y:0,z:0)),nil)
expect(events == [true,false],"previous generation cannot leak into next session")
sensor.send(1.2);expect(events == [true,false,true],"new live generation")
owner!.setActive(false);expect(events == [true,false,true,false],"menu/background immediately release")
owner!.setActive(true);sensor.send(1.2)
sensor.receiver?(nil,NSError(domain:"test",code:1))
expect(events.suffix(2)==[true,false],"sensor errors release controls")
owner!.setActive(true);sensor.send(1.2)
weak var weakOwner=owner;owner=nil
expect(weakOwner==nil && events.suffix(2)==[true,false],"deinit stops and has no retention cycle")
let count=events.count;RunLoop.main.run(until:Date().addingTimeInterval(0.18))
expect(events.count==count,"cancelled timers cannot release a new gesture")
var absent:DolphinPhoneShake?=DolphinPhoneShake{_ in preconditionFailure("unavailable sensor emitted")}
let unavailable=CMMotionManager.last!;unavailable.isDeviceMotionAvailable=false
absent!.setActive(true);expect(unavailable.starts==0,"unavailable sensor does nothing");absent=nil
print("PASS: \(cases) production shake policy/detection/lifecycle assertions; simulated sensor, no device claim")
'''
source=(TOUCH/'DolphinPhoneShake.swift').read_text()
assert source.count('import CoreMotion')==1
with tempfile.TemporaryDirectory() as tmp:
    folder=Path(tmp)
    (folder/'Sensor.swift').write_text(STUB)
    (folder/'Owner.swift').write_text(source.replace('import CoreMotion',''))
    (folder/'main.swift').write_text(MAIN)
    binary=folder/'shake-test'
    subprocess.run(['swiftc','-swift-version','5',str(TOUCH/'DolphinShakeDetector.swift'),
                    str(folder/'Sensor.swift'),str(folder/'Owner.swift'),str(folder/'main.swift'),
                    '-o',str(binary)],check=True)
    result=subprocess.run([str(binary)],text=True,capture_output=True,check=True)
    print(result.stdout)
    output=ROOT/'build/dolphin-motion/tests.json'
    output.parent.mkdir(parents=True,exist_ok=True)
    output.write_text(json.dumps({'productionSwiftExecuted':True,'sensor':'mocked',
        'realDeviceValidated':False,'result':result.stdout.strip()},indent=2)+'\n')
