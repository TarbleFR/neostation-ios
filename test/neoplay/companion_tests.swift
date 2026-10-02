import XCTest
import UIKit
@testable import NPCheck

@objc(DOLDolphinViewController) final class NPDolphinMenuFixture: NSObject { @objc func menuPressed(_ sender: Any) {} }
@objc(Armsx2GameViewController) final class NPArmsMenuFixture: NSObject { @objc func menuPressed() {} }
@objc(RPCS3GameViewController) final class NPRpcsMenuFixture: NSObject { @objc func menuPressed() {} }
@objc(NeoDusklightControls) final class NPDuskMenuFixture: NSObject { @objc func openMenu() {} }
@objc(KartPadGameOverlay) final class NPKartMenuFixture: UIView {}

final class NeoPlayCompanionTests: XCTestCase {
    func testBatteryUnknownAndInvalidNeverBecomeFakePercentages() {
        XCTAssertNil(NPBatteryValue(level:nil,charge:.unknown).percent)
        XCTAssertNil(NPBatteryValue(level:0,charge:.unknown).percent)
        XCTAssertNil(NPBatteryValue(level:1,charge:.unknown).percent)
        for value in [Float.nan,Float.infinity,-0.1,1.1] { XCTAssertNil(NPBatteryValue(level:value,charge:.discharging).percent) }
        XCTAssertEqual(NPBatteryValue(level:0,charge:.discharging).percent,0)
        XCTAssertEqual(NPBatteryValue(level:0.78,charge:.discharging).percent,78)
        XCTAssertEqual(NPBatteryValue(level:1,charge:.full).percent,100)
        XCTAssertNil(NPBatteryValue(level:0,charge:.full).percent)
        XCTAssertTrue(NPBatteryValue(level:0.15,charge:.discharging).low)
        XCTAssertFalse(NPBatteryValue(level:0.15,charge:.charging).low)
    }
    func testAirPlayAudioIsNeverReportedAsVideoOrSpecificAppleTV() {
        XCTAssertEqual(NPAirPlayFacts(externalMirroring:false,airPlayAudio:false).status,"notDetected")
        XCTAssertEqual(NPAirPlayFacts(externalMirroring:false,airPlayAudio:true).status,"audioOnly")
        XCTAssertEqual(NPAirPlayFacts(externalMirroring:true,airPlayAudio:false).status,"mirrorDetected")
        XCTAssertFalse(NPAirPlayFacts(externalMirroring:true,airPlayAudio:true).exactReceiverIdentified)
    }
    func testPlacementDoesNotCoverMenuPerformanceOrSafeArea() throws {
        let safe = CGRect(x:20,y:20,width:760,height:340), menu = CGRect(x:32,y:32,width:44,height:44), performance = CGRect(x:84,y:32,width:44,height:44)
        let frame = try XCTUnwrap(NPCompanionPlacement.frame(anchor:menu,safe:safe,size:CGSize(width:90,height:30),obstacles:[performance]))
        XCTAssertTrue(safe.contains(frame)); XCTAssertFalse(frame.intersects(menu)); XCTAssertFalse(frame.intersects(performance))
        let right = CGRect(x:728,y:32,width:44,height:44)
        let second = try XCTUnwrap(NPCompanionPlacement.frame(anchor:right,safe:safe,size:CGSize(width:90,height:30),obstacles:[]))
        XCTAssertLessThan(second.maxX,right.minX)
        XCTAssertNil(NPCompanionPlacement.frame(anchor:menu,safe:safe,size:CGSize(width:999,height:30),obstacles:[]))
        XCTAssertNil(NPCompanionPlacement.frame(anchor:menu,safe:safe,size:CGSize(width:90,height:30),obstacles:[safe]))
    }
    func testAllFiveExistingNativeMenuAdaptersWithoutMutatingTargets() {
        let fixtures: [(NSObject,Selector,String)] = [(NPDolphinMenuFixture(),#selector(NPDolphinMenuFixture.menuPressed(_:)),"dolphin"),(NPArmsMenuFixture(),#selector(NPArmsMenuFixture.menuPressed),"armsx2"),(NPRpcsMenuFixture(),#selector(NPRpcsMenuFixture.menuPressed),"rpcs3"),(NPDuskMenuFixture(),#selector(NPDuskMenuFixture.openMenu),"dusklight")]
        for (target,selector,kind) in fixtures {
            let button = UIButton(); button.addTarget(target,action:selector,for:.touchUpInside)
            let actions = button.actions(forTarget:target,forControlEvent:.touchUpInside)
            XCTAssertEqual(NPGameHUDAnchor.kind(of:button),kind)
            XCTAssertEqual(button.actions(forTarget:target,forControlEvent:.touchUpInside),actions)
        }
        let parent = NPKartMenuFixture(), menu = UIButton(); menu.accessibilityLabel = "Menu"; menu.menu = UIMenu(children:[])
        parent.addSubview(menu); XCTAssertEqual(NPGameHUDAnchor.kind(of:menu),"kartpad")
        XCTAssertTrue(NPGameHUDAnchor.find(in:parent) === menu)
        menu.removeFromSuperview(); XCTAssertNil(NPGameHUDAnchor.kind(of:menu))
        XCTAssertNil(NPGameHUDAnchor.kind(of:UIButton()))
    }
    func testHUDPassesTouchesAndIdentifiesUnknownChargingAndMultipleControllers() {
        let window = UIWindow(frame:CGRect(x:0,y:0,width:844,height:390))
        let parent = UIView(frame:window.bounds); window.addSubview(parent)
        let button = UIButton(frame:CGRect(x:10,y:10,width:44,height:44)); parent.addSubview(button)
        let hud = NPBatteryHUDView(frame:CGRect(x:60,y:10,width:200,height:40)); parent.addSubview(hud)
        let first = NSObject(), second = NSObject()
        let rows = [NPControllerBatteryReading(id:ObjectIdentifier(first),player:1,name:"Pad A",value:NPBatteryValue(level:0.78,charge:.charging)),NPControllerBatteryReading(id:ObjectIdentifier(second),player:2,name:"Pad B",value:NPBatteryValue(level:nil,charge:.unknown))]
        let size = hud.configure(rows,labels:["battery":"Battery","controller":"Controller {number}","percent":"{value}%","unavailable":"Unknown","charging":"Charging","low":"Low"],maximumWidth:300)
        XCTAssertGreaterThan(size.width,100); XCTAssertFalse(hud.isUserInteractionEnabled)
        XCTAssertTrue(parent.hitTest(CGPoint(x:20,y:20),with:nil) === button)
        XCTAssertTrue(parent.hitTest(CGPoint(x:80,y:20),with:nil) === parent)
        let pills = (hud.subviews.first as? UIStackView)?.arrangedSubviews ?? []
        XCTAssertEqual(pills.count,2); XCTAssertTrue(pills[0].accessibilityValue!.contains("78%")); XCTAssertTrue(pills[0].accessibilityValue!.contains("Charging"))
        XCTAssertEqual(pills[1].accessibilityValue,"Unknown")
        XCTAssertTrue(pills[1].accessibilityLabel!.contains("Pad B"))
        for _ in 0..<20 { hud.removeFromSuperview(); parent.addSubview(hud) }
        XCTAssertEqual(parent.subviews.filter { $0 is NPBatteryHUDView }.count,1)
    }
}
