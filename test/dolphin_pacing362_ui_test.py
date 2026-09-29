from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
origin=ROOT/'test/dolphin_account_267_test.py'
source=origin.read_text().replace("'CLANG_ENABLE_OBJC_ARC': 'YES',", "'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_CXX_LANGUAGE_STANDARD': 'c++20',")
source=source.replace("{'sdk': 'UIKit.framework'}", "{'sdk': 'UniformTypeIdentifiers.framework'}, {'sdk': 'UIKit.framework'}")
ns={'__file__':str(origin),'__name__':'pacing_tests'}
exec(compile(source,str(origin),'exec'),ns)
ns['TESTS']=r'''
#import <XCTest/XCTest.h>
#import "DolphinFramePacing.h"
#import "DolphinSessionMenu.h"
@interface DolphinFramePacing (TestAccess)
- (void)tick:(CADisplayLink*)link;
@end
@interface FakeTick:NSObject
@property double timestamp;
@property double targetTimestamp;
@end
@implementation FakeTick @end
@interface FramePacing362Tests:XCTestCase @end
@implementation FramePacing362Tests
- (void)setUp {
 for(NSString* key in @[@"Profile",@"Refresh",@"Trace"])
  [NSUserDefaults.standardUserDefaults removeObjectForKey:[@"NeoStation.Dolphin.DisplayTrial." stringByAppendingString:key]];
}
- (void)testRefreshRequestsRespectHardwarePowerAndHeat {
 XCTAssertEqual(DOLRequestedRefresh(120,120,NO,0),120);
 XCTAssertEqual(DOLRequestedRefresh(120,60,NO,0),60);
 XCTAssertEqual(DOLRequestedRefresh(120,120,YES,0),60);
 XCTAssertEqual(DOLRequestedRefresh(120,120,NO,2),60);
 XCTAssertEqual(DOLRequestedRefresh(120,120,NO,3),60);
 XCTAssertEqual(DOLRequestedRefresh(60,120,NO,0),60);
 XCTAssertEqual(DOLRequestedRefresh(0,120,NO,0),0);
 XCTAssertEqual(DOLRequestedRefresh(120,0,NO,0),0);
}
- (void)testTraceIsBoundedAndDisplayCallbackMeasurementIsNotGameFPS {
 DolphinFramePacing* tracker=[DolphinFramePacing new];UIView* view=[UIView new];[tracker startWithView:view];
 FakeTick* tick=[FakeTick new];
 for(int i=0;i<241;i++){tick.timestamp=10+i/120.0;tick.targetTimestamp=tick.timestamp+1/120.0;[tracker tick:(id)tick];}
 XCTAssertEqualWithAccuracy([tracker.summary[@"displayLinkCallbackHz"] doubleValue],120,0.5);
 for(int i=0;i<600;i++)[tracker appendPerformance:@{@"fps":@60,@"vps":@60,@"frameTimeMs":@16.67} inputMs:0 refreshed:NO];
 XCTAssertEqual(tracker.samples.count,240);XCTAssertEqualObjects(tracker.samples.lastObject[@"fps"],@60);
 XCTAssertTrue([tracker.summary[@"measurementNote"] containsString:@"not panel"]);
 [tracker stop];[tracker appendPerformance:@{@"fps":@60} inputMs:0 refreshed:NO];XCTAssertEqual(tracker.samples.count,240);
}
- (void)testStopInvalidatesActualDisplayLinkAndNoRetainCycle {
 UIWindow* window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
 UIViewController* root=[UIViewController new];window.rootViewController=root;[window makeKeyAndVisible];
 __weak DolphinFramePacing* weak=nil;
 @autoreleasepool {
  DolphinFramePacing* tracker=[DolphinFramePacing new];weak=tracker;[tracker startWithView:root.view];
  XCTAssertNotNil([tracker valueForKey:@"displayLink"]);
  [tracker stop];XCTAssertNil([tracker valueForKey:@"displayLink"]);
 }
 XCTAssertNil(weak);window.hidden=YES;
}
- (void)testNativeSettingsAndTwelveLanguages {
 DolphinFramePacing* tracker=[DolphinFramePacing new];tracker.locale=@"fr";
 UITableViewController* page=(id)[tracker settingsController];[page loadViewIfNeeded];
 XCTAssertEqual([page.tableView.dataSource tableView:page.tableView numberOfRowsInSection:0],6);
 XCTAssertEqualObjects(page.title,@"Affichage et fluidité");XCTAssertEqual(DOLFrameProfile(),2);
 for(NSString* lang in @[@"en",@"fr",@"de",@"es",@"it",@"pt",@"ru",@"id",@"ja",@"ko",@"zh",@"zh_Hant"])
  for(NSString* key in @[@"title",@"hzHelp",@"profileHelp",@"restore"])
   XCTAssertNotEqualObjects(DOLPacingText(key,lang),key);
}
- (void)testGraphicsMenuOpensDisplayPanelWithoutChangingTheEmulator {
 DolphinSessionMenu* menu=[DolphinSessionMenu new];menu.labels=@{@"__locale":@"fr"};
 [menu setValue:@1 forKey:@"page"];[menu setValue:@{} forKey:@"snapshot"];__block BOOL opened=NO;
 menu.openDisplaySettings=^{opened=YES;};[menu loadViewIfNeeded];
 NSIndexPath* row=[NSIndexPath indexPathForRow:4 inSection:0];
 XCTAssertEqual([menu tableView:menu.tableView numberOfRowsInSection:0],5);
 XCTAssertEqualObjects([menu tableView:menu.tableView cellForRowAtIndexPath:row].textLabel.text,@"Affichage et fluidité");
 [menu tableView:menu.tableView didSelectRowAtIndexPath:row];XCTAssertTrue(opened);
}
@end
'''
ns['native']()
