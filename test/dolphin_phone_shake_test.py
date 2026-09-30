#!/usr/bin/env python3
"""Execute production policy, sensor lifecycle and blocked-main regressions.

CoreMotion is mocked; game acceptance on a physical iPhone remains unvalidated.
The real CoreMotion/TouchController API is separately type-checked for iOS.
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
  private let lock=NSLock()
  private var starts=0,stops=0
  var receiver:((CMDeviceMotion?,Error?)->Void)?
  private var deliveryQueue:OperationQueue?
  init(){Self.last=self}
  var counts:(Int,Int) {lock.lock();defer{lock.unlock()};return(starts,stops)}
  func startDeviceMotionUpdates(to queue:OperationQueue,withHandler handler:@escaping(CMDeviceMotion?,Error?)->Void){
    lock.lock();starts+=1;receiver=handler;deliveryQueue=queue;lock.unlock()
  }
  func stopDeviceMotionUpdates(){lock.lock();stops+=1;lock.unlock()}
  func deliver(_ handler:@escaping(CMDeviceMotion?,Error?)->Void,_ motion:CMDeviceMotion?,_ error:Error?=nil){
    lock.lock();let queue=deliveryQueue;lock.unlock()
    guard let queue=queue else{return}
    if queue === OperationQueue.main && Thread.isMainThread {handler(motion,error);return}
    queue.addOperations([BlockOperation{handler(motion,error)}],waitUntilFinished:true)
  }
  func send(_ strength:Double,age:Double=0){
    lock.lock();let callback=receiver;lock.unlock()
    if let callback=callback {deliver(callback,CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime-age,userAcceleration:CMAcceleration(x:strength,y:0,z:0)))}
  }
}
final class EventLog {
  private var values=[Bool]()
  private let lock=NSLock()
  private(set) var emittedOnMain=false
  func append(_ value:Bool){lock.lock();values.append(value);if Thread.isMainThread{emittedOnMain=true};lock.unlock()}
  func clear(){lock.lock();values=[];lock.unlock()}
  var snapshot:[Bool] {lock.lock();defer{lock.unlock()};return values}
}
final class PrepareState {
  private let lock=NSLock()
  private var value=false
  var ready:Bool {get{lock.lock();defer{lock.unlock()};return value}set{lock.lock();value=newValue;lock.unlock()}}
}
'''
MAIN=r'''
import Foundation
var cases=0
func expect(_ value:Bool,_ label:String){precondition(value,label);cases+=1}
func eventually(_ condition:()->Bool)->Bool {
 let until=ProcessInfo.processInfo.systemUptime+1
 while !condition() && ProcessInfo.processInfo.systemUptime<until {Thread.sleep(forTimeInterval:0.001)}
 return condition()
}
for mask in 0..<256 {
  let bits=(0..<8).map{mask & (1 << $0) != 0}
  let accepted=DolphinPhoneShakePolicy.acceptsInput(wii:bits[0],remoteLayout:bits[1],sessionRunning:bits[2],visible:bits[3],touchEnabled:bits[4],appActive:bits[5],physicalController:bits[6],enabled:bits[7])
  expect(accepted == (bits[0] && bits[1] && bits[2] && (bits[3] || bits[6]) && bits[4] && bits[5] && bits[7]),"lifecycle gate \(mask)")
}
expect(DolphinPhoneShakePolicy.acceptsInput(wii:true,remoteLayout:true,sessionRunning:true,visible:false,touchEnabled:true,appActive:true,physicalController:true,enabled:true),"gamepad-hidden overlay still accepts phone gestures")
expect(!DolphinPhoneShakePolicy.acceptsInput(wii:true,remoteLayout:true,sessionRunning:true,visible:false,touchEnabled:false,appActive:true,physicalController:true,enabled:true),"gamepad never bypasses menu disable")
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
let events=EventLog()
var owner:DolphinPhoneShake?=DolphinPhoneShake{events.append($0)}
let sensor=CMMotionManager.last!
owner!.setActive(true);owner!.setActive(true)
expect(eventually{sensor.counts.0==1},"idempotent asynchronous sensor start")
sensor.send(1.2,age:0.5);expect(events.snapshot.isEmpty,"backlogged sensor gesture discarded")
sensor.send(1.2);expect(events.snapshot == [true],"one virtual shake press")
expect(eventually{events.snapshot == [true,false]},"automatic release independent of main run loop")
owner!.stop();expect(eventually{sensor.counts.1>=1},"sensor stop processed")
let old=sensor.receiver!
sensor.deliver(old,CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime,userAcceleration:CMAcceleration(x:2,y:0,z:0)))
expect(events.snapshot == [true,false],"queued callbacks ignored after stop")
owner!.setActive(true);expect(eventually{sensor.counts.0==2},"new sensor generation starts")
sensor.deliver(old,CMDeviceMotion(timestamp:ProcessInfo.processInfo.systemUptime,userAcceleration:CMAcceleration(x:2,y:0,z:0)))
expect(events.snapshot == [true,false],"previous generation cannot leak into next session")
sensor.send(1.2);expect(events.snapshot == [true,false,true],"new live generation")
owner!.setActive(false)
expect(eventually{events.snapshot == [true,false,true,false]},"menu/background releases controls")
owner!.setActive(true);expect(eventually{sensor.counts.0==3},"restart after suspension")
sensor.send(1.2);sensor.deliver(sensor.receiver!,nil,NSError(domain:"test",code:1))
expect(events.snapshot.suffix(2)==[true,false],"sensor errors release controls")
owner!.setActive(true);expect(eventually{sensor.counts.0==4},"sensor-error retry")
events.clear()
let completed=DispatchSemaphore(value:0)
DispatchQueue.global().async {sensor.send(1.2);completed.signal()}
// Deliberately block UI for longer than the old 100 ms freshness gate and
// the 120 ms pulse. The live gesture AND its release must still reach input.
Thread.sleep(forTimeInterval:0.22)
expect(events.snapshot == [true,false],"live press and release survive blocked main thread")
expect(completed.wait(timeout:.now()+0.2) == .success,"sensor callback completed without main")
expect(!events.emittedOnMain,"input injection never uses UIKit main")
owner!.setActive(false);expect(eventually{sensor.counts.1>=4},"final suspend")
owner!.setActive(true);expect(eventually{sensor.counts.0==5},"final session")
sensor.send(1.2)
weak var weakOwner=owner;owner=nil
expect(eventually{weakOwner==nil && events.snapshot.suffix(2)==[true,false]},"deinit stops and has no retention cycle")
let count=events.snapshot.count;Thread.sleep(forTimeInterval:0.18)
expect(events.snapshot.count==count,"cancelled timers cannot release a new gesture")
let unavailableEvents=EventLog()
var absent:DolphinPhoneShake?=DolphinPhoneShake(unavailable:{unavailableEvents.append(true)}){_ in preconditionFailure("unavailable sensor emitted")}
let unavailable=CMMotionManager.last!;unavailable.isDeviceMotionAvailable=false
absent!.setActive(true)
expect(eventually{unavailable.counts.0==0 && unavailableEvents.snapshot == [true]},"unavailable sensor reports diagnostic without starting");absent=nil
// Preparation may wait on Dolphin runtime. Main must remain responsive, and
// a menu/stop while preparation is pending must prevent a late sensor start.
let preparing=DispatchSemaphore(value:0),allowPrepare=DispatchSemaphore(value:0)
var pending:DolphinPhoneShake?=DolphinPhoneShake(prepare:{preparing.signal();allowPrepare.wait();return true}){_ in preconditionFailure("cancelled preparation emitted")}
let pendingSensor=CMMotionManager.last!
pending!.setActive(true)
expect(preparing.wait(timeout:.now()+0.5) == .success,"route preparation is asynchronous to main")
pending!.setActive(false);allowPrepare.signal()
expect(eventually{pendingSensor.counts.1>0},"pending route cancellation processed")
expect(pendingSensor.counts.0==0,"cancelled preparation cannot start sensors later");pending=nil
// Actual Dolphin profile refresh can follow an earlier GC notification. Its
// preparation runs again without a sensor reset or deliberate-shake rearming.
let routeCalls=EventLog(),routeEvents=EventLog()
var routed:DolphinPhoneShake?=DolphinPhoneShake(prepare:{routeCalls.append(true);return true}){routeEvents.append($0)}
let routeSensor=CMMotionManager.last!
routed!.setActive(true);expect(eventually{routeSensor.counts.0==1},"initial route sensor starts")
routeSensor.send(1.2);expect(routeEvents.snapshot == [true],"initial route gesture")
routed!.refreshRouting()
expect(eventually{routeCalls.snapshot.count==2},"late effective profile refresh re-qualifies phone source")
expect(routeSensor.counts.0==1 && routeSensor.counts.1==0,"requalification preserves live sensor lifecycle")
Thread.sleep(forTimeInterval:0.35)
routeSensor.send(1.2)
expect(routeEvents.snapshot == [true,false],"profile refresh does not rearm continuous movement")
routed=nil
let retryState=PrepareState(),retryCalls=EventLog()
var retry:DolphinPhoneShake?=DolphinPhoneShake(prepare:{retryCalls.append(true);return retryState.ready}){_ in}
let retrySensor=CMMotionManager.last!
retry!.setActive(true);expect(eventually{retryCalls.snapshot.count==1},"failed initial route attempted")
expect(retrySensor.counts.0==0,"failed route never starts sensor")
retryState.ready=true;retry!.refreshRouting()
expect(eventually{retrySensor.counts.0==1},"actual profile refresh recovers failed initial route");retry=nil
let blockedCalls=EventLog(),blockedEvents=EventLog()
let routeBlocked=DispatchSemaphore(value:0),routeAllowed=DispatchSemaphore(value:0)
var blocked:DolphinPhoneShake?=DolphinPhoneShake(prepare:{
 blockedCalls.append(true)
 if blockedCalls.snapshot.count==2 {routeBlocked.signal();routeAllowed.wait()}
 return true
}){blockedEvents.append($0)}
let blockedSensor=CMMotionManager.last!
blocked!.setActive(true);expect(eventually{blockedSensor.counts.0==1},"blocking reprepare fixture starts")
blockedSensor.send(1.2);expect(blockedEvents.snapshot == [true],"held shake before reprepare")
blocked!.refreshRouting()
expect(routeBlocked.wait(timeout:.now()+0.5) == .success,"native reprepare is waiting")
expect(blockedEvents.snapshot == [true,false],"reprepare releases held shake before waiting on runtime")
blocked!.setActive(false);routeAllowed.signal()
expect(eventually{blockedSensor.counts.1>0},"stop during reprepare processed")
expect(blockedSensor.counts.0==1 && blockedEvents.snapshot == [true,false],"late reprepare cannot reactivate input after stop");blocked=nil
print("PASS: \(cases) production shake policy/worker/lifecycle assertions; sensor mocked, no device claim")
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
        'mainThreadStallRegression':True,'realDeviceValidated':False,
        'result':result.stdout.strip()},indent=2)+'\n')
