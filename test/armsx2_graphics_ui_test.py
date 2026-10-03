#!/usr/bin/env python3
"""Execute the actual Graphics -> Shaders/OSD menu on UIKit, without a VM."""
from pathlib import Path
import importlib.util
ROOT=Path(__file__).resolve().parents[1]
# Reuse the existing simulator/project harness; no Dolphin contract or core runs.
spec=importlib.util.spec_from_file_location('sim_harness',ROOT/'test/dolphin_account_267_test.py')
harness=importlib.util.module_from_spec(spec);spec.loader.exec_module(harness)
source=(ROOT/'test/dolphin_account_267_test.py').read_text()
start=source.index('def native():');end=source.index("if __name__ == '__main__':",start)
runner=source[start:end].replace('DolphinAccount267','ARMSX2Graphics26').replace('DolphinAccountHost','ARMSX2GraphicsHost').replace('DolphinAccountTests','ARMSX2GraphicsTests')
runner=runner.replace('str(CLASSES / \'DolphinSessionMenu.mm\')','str(CLASSES / \'Armsx2SessionMenu.mm\')').replace('str(CLASSES / \'DolphinRetroAchievementsAccount.mm\')','str(CLASSES / \'Armsx2RetroAchievementsMenu.mm\')').replace('str(CLASSES / \'DolphinFramePacing.mm\')','str(CLASSES / \'ARMSX2InGameLocalization.mm\')')
runner=runner.replace("'CLANG_ENABLE_OBJC_ARC': 'YES'","'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_CXX_LANGUAGE_STANDARD': 'c++20'")
runner=runner.replace("{'sdk': 'UIKit.framework'}","{'sdk': 'libz.tbd'}, {'sdk': 'UniformTypeIdentifiers.framework'}, {'sdk': 'UIKit.framework'}")
ns=dict(vars(harness));ns['CLASSES']=ROOT/'packages/armsx2_internal_bridge/ios/Classes'
ns['TESTS']=r'''
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "Armsx2SessionMenu.h"
@interface ARMSX2GraphicsTests : XCTestCase
@end
@implementation ARMSX2GraphicsTests
- (NSDictionary*)snapshot {
 return @{@"upscale":@1,@"aspect":@0,@"graphicsAssets":@{@"supported":@YES,@"overlay":@0,@"selected":@"",@"presets":@[@{@"id":@"bundle:presets/crt.slangp",@"name":@"CRT"}],@"packInstalled":@NO,@"shaderError":@""}};
}
- (Armsx2SessionMenu*)menu:(__strong UINavigationController**)navigation {
 Armsx2SessionMenu* menu=[Armsx2SessionMenu new];menu.localeIdentifier=@"fr";
 menu.readSnapshot=^(void (^done)(NSDictionary*)){done([self snapshot]);};
 *navigation=[[UINavigationController alloc] initWithRootViewController:menu];
 [*navigation loadViewIfNeeded];[menu loadViewIfNeeded];[menu viewWillAppear:NO];
 // Exercise production root navigation; no private enum constants are assumed.
 [menu tableView:menu.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
 Armsx2SessionMenu* graphics=(id)(*navigation).topViewController;[graphics loadViewIfNeeded];
 return graphics;
}
- (void)testGraphicsGroupsBothFeaturesAndShaderSelectionUsesStableToken {
 UINavigationController* nav=nil;Armsx2SessionMenu* graphics=[self menu:&nav];
 XCTAssertEqual([graphics tableView:graphics.tableView numberOfRowsInSection:0],5);
 XCTAssertEqualObjects([graphics tableView:graphics.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]].textLabel.text,@"Shaders");
 __block NSString* command=nil;__block id value=nil;
 graphics.performCommand=^(NSString* c,id v,void (^done)(BOOL,NSString*)){command=c;value=v;done(YES,@"");};
 [graphics tableView:graphics.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
 Armsx2SessionMenu* shaders=(id)nav.topViewController;[shaders loadViewIfNeeded];
 XCTAssertEqual([shaders tableView:shaders.tableView numberOfRowsInSection:0],3);
 [shaders tableView:shaders.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
 XCTAssertEqualObjects(command,@"shader");XCTAssertEqualObjects(value,@"bundle:presets/crt.slangp");
 [shaders tableView:shaders.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
 XCTAssertEqualObjects(value,@"");
 [shaders tableView:shaders.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
 XCTAssertEqualObjects(command,@"downloadShaders");
}
- (void)testOverlayChoicesReachNativeCommandAndPreserveResolution {
 UINavigationController* nav=nil;Armsx2SessionMenu* graphics=[self menu:&nav];
 __block NSString* command=nil;__block id value=nil;
 graphics.performCommand=^(NSString* c,id v,void (^done)(BOOL,NSString*)){command=c;value=v;done(YES,@"");};
 [graphics tableView:graphics.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
 UITableViewController* overlay=(id)nav.topViewController;[overlay loadViewIfNeeded];
 XCTAssertEqual([overlay tableView:overlay.tableView numberOfRowsInSection:0],4);
 [overlay tableView:overlay.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:3 inSection:0]];
 XCTAssertEqualObjects(command,@"overlay");XCTAssertEqualObjects(value,@3);
 XCTAssertEqualObjects([graphics valueForKey:@"snapshot"][@"upscale"],@1);
}
@end
'''
exec(compile(runner,__file__,'exec'),ns);ns['native']()
