#!/usr/bin/env python3
"""Source contracts plus real UIKit/XCTest regression tests on an iOS simulator."""
from pathlib import Path
import argparse
import json
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
CLASSES = ROOT / 'packages/dolphin_internal_bridge/ios/Classes'

TESTS = r'''
#import <XCTest/XCTest.h>
#import "DolphinSessionMenu.h"
#import "DolphinRetroAchievementsAccount.h"

@interface DolphinSessionMenu (AccountTesting)
- (void)apply:(NSDictionary*)request thenReturn:(BOOL)returnToBindings;
@end
@interface DolphinAccountTests : XCTestCase
@end
@implementation DolphinAccountTests
- (DolphinSessionMenu*)accountMenu {
  DolphinSessionMenu* menu = [DolphinSessionMenu new];
  menu.labels = @{@"raAccount": @"Account", @"resume": @"Resume", @"back": @"Back"};
  [menu setValue:@3 forKey:@"page"];
  [menu setValue:@{@"achievements": @{@"enabled": @NO, @"username": NSNull.null,
      @"gameLoaded": @NO, @"hardcore": @NO}} forKey:@"snapshot"];
  [menu loadViewIfNeeded];
  return menu;
}
- (void)testAccountTapOpensDedicatedScreenAndNeverAppliesSettings {
  DolphinSessionMenu* menu = [self accountMenu];
  __block NSUInteger calls = 0;
  menu.applySettings = ^(NSDictionary* request, void (^done)(BOOL)) { ++calls; done(YES); };
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:menu];
  [navigation loadViewIfNeeded];
  NSIndexPath* account = [NSIndexPath indexPathForRow:0 inSection:0];
  XCTAssertNoThrow([menu tableView:menu.tableView didSelectRowAtIndexPath:account]);
  XCTAssertTrue([navigation.topViewController isKindOfClass:DolphinRetroAchievementsAccount.class]);
  XCTAssertEqual(navigation.viewControllers.count, 2U);
  XCTAssertNoThrow([navigation.topViewController loadViewIfNeeded]);
  // A repeated tap from the old page must not open a second form.
  [menu tableView:menu.tableView didSelectRowAtIndexPath:account];
  XCTAssertEqual(navigation.viewControllers.count, 2U);
  XCTAssertEqual(calls, 0U);
}
- (void)testStatusAndModeAreReadOnly {
  DolphinSessionMenu* menu = [self accountMenu];
  __block NSUInteger calls = 0;
  menu.applySettings = ^(NSDictionary* request, void (^done)(BOOL)) { ++calls; done(YES); };
  for (NSInteger row = 1; row <= 2; ++row) {
    NSIndexPath* index = [NSIndexPath indexPathForRow:row inSection:0];
    UITableViewCell* cell = [menu tableView:menu.tableView cellForRowAtIndexPath:index];
    XCTAssertFalse(cell.userInteractionEnabled);
    XCTAssertEqual(cell.selectionStyle, UITableViewCellSelectionStyleNone);
    XCTAssertNoThrow([menu tableView:menu.tableView didSelectRowAtIndexPath:index]);
  }
  XCTAssertEqual(calls, 0U);
}
- (void)testOutOfRangeAndUnknownPageTapsDoNothing {
  DolphinSessionMenu* menu = [self accountMenu];
  XCTAssertNoThrow([menu tableView:menu.tableView didSelectRowAtIndexPath:
      [NSIndexPath indexPathForRow:99 inSection:0]]);
  [menu setValue:@99 forKey:@"page"];
  XCTAssertNoThrow([menu tableView:menu.tableView didSelectRowAtIndexPath:
      [NSIndexPath indexPathForRow:0 inSection:0]]);
}
- (void)testSerializerRejectsNilNullWrongKindsAndNonJSONValues {
  XCTAssertNil(DOLSerializeMenuRequest(nil));
  XCTAssertNil(DOLSerializeMenuRequest(NSNull.null));
  XCTAssertNil(DOLSerializeMenuRequest(@[]));
  XCTAssertNil(DOLSerializeMenuRequest(@{}));
  XCTAssertNil(DOLSerializeMenuRequest(@{@"kind": NSNull.null}));
  XCTAssertNil(DOLSerializeMenuRequest(@{@"kind": @""}));
  XCTAssertNil(DOLSerializeMenuRequest(@{@"kind": @"hack", @"value": [NSObject new]}));
  XCTAssertNotNil(DOLSerializeMenuRequest(@{@"kind": @"hack", @"key": @"viSkip", @"value": @NO}));
}
- (void)testNilRequestCannotReachNativeSettingsCallback {
  DolphinSessionMenu* menu = [self accountMenu];
  __block NSUInteger calls = 0;
  menu.applySettings = ^(NSDictionary* request, void (^done)(BOOL)) { ++calls; done(YES); };
  XCTAssertNoThrow([menu apply:(id)nil thenReturn:NO]);
  XCTAssertEqual(calls, 0U);
}
- (void)testPasswordIsPOSTEncodedNotAddedToURL {
  NSURLRequest* request = [DolphinRetroAchievementsAccount loginRequestForUsername:@" User " password:@" p+&%=é "];
  XCTAssertEqualObjects(request.URL.absoluteString, @"https://retroachievements.org/dorequest.php");
  XCTAssertEqualObjects(request.HTTPMethod, @"POST");
  XCTAssertEqualObjects([[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding],
      @"r=login2&u=User&p=%20p%2B%26%25%3D%C3%A9%20");
  XCTAssertNil([DolphinRetroAchievementsAccount loginRequestForUsername:@" " password:@"x"]);
  XCTAssertNil([DolphinRetroAchievementsAccount loginRequestForUsername:@"User" password:@""]);
}
- (void)testLoginResponseRequiresSuccessUsernameAndEmulatorToken {
  NSArray<NSString*>* rejected = @[@"", @"null", @"[]", @"{}", @"<html>offline</html>",
    @"{\"Success\":false,\"User\":\"u\",\"Token\":\"t\"}",
    @"{\"Success\":true,\"User\":null,\"Token\":\"t\"}",
    @"{\"Success\":true,\"User\":\"u\",\"Token\":\"\"}",
    @"{\"Success\":true,\"User\":\"u\",\"Token\":17}"];
  for (NSString* json in rejected)
    XCTAssertNil([DolphinRetroAchievementsAccount credentialsFromResponse:[json dataUsingEncoding:NSUTF8StringEncoding]]);
  NSData* valid = [@"{\"Success\":true,\"User\":\"Player\",\"Token\":\"test-token\"}"
      dataUsingEncoding:NSUTF8StringEncoding];
  XCTAssertEqualObjects([DolphinRetroAchievementsAccount credentialsFromResponse:valid],
      (@{@"username": @"Player", @"token": @"test-token"}));
}
- (void)testRedirectIsRefused {
  DolphinRetroAchievementsAccount* controller = [[DolphinRetroAchievementsAccount alloc] initWithLabels:@{}];
  __block BOOL completed = NO;
  [controller URLSession:(id)nil task:(id)nil willPerformHTTPRedirection:(id)nil
      newRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"http://example.invalid"]]
      completionHandler:^(NSURLRequest* redirected) { XCTAssertNil(redirected); completed = YES; }];
  XCTAssertTrue(completed);
}
@end
'''

APP = r'''
#import <UIKit/UIKit.h>
@interface AccountTestDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end
@implementation AccountTestDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  [self.window makeKeyAndVisible];
  return YES;
}
@end
int main(int argc, char** argv) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AccountTestDelegate.class)); }
}
'''


def contracts():
    paths = [CLASSES / 'DolphinSessionMenu.mm', CLASSES / 'DolphinInternalBridgePlugin.mm',
             CLASSES / 'DolphinRetroAchievementsAccount.mm', CLASSES / 'DolphinRetroAchievementsAccount.h',
             ROOT / 'lib/l10n/dolphin_import_locale.dart']
    before = [p.read_bytes() for p in paths]
    subprocess.run(['python3', str(ROOT / 'build-utils/patch_dolphin_build267_account.py')], check=True)
    assert before == [p.read_bytes() for p in paths], 'Patch must be idempotent'
    menu, host, account, header, locale = [p.read_text() for p in paths]
    assert 'NEOSTATION_DOLPHIN_ACCOUNT_267' in menu
    assert 'else if (self.page == DOLMenuChoices)' in menu
    assert 'if (!DOLSerializeMenuRequest(request))' in menu
    assert 'NSData* data = DOLSerializeMenuRequest(request)' in host
    assert 'raCredentials[@"token"]' in host
    assert 'NSString* raApiToken = [arguments[' not in host
    for token in ['secureTextEntry = YES', 'ephemeralSessionConfiguration', 'requestGeneration',
                  'credentialsFromResponse', 'SecItemUpdate', 'SecItemDelete', 'completionHandler(nil)']:
        assert token in account, token
    block = locale.split('static const _accountMenu = <String, Map<String, String>>', 1)[1].split(';', 1)[0]
    translations = json.loads(block)
    assert len(translations) == 12
    all_keys = set(translations['en'])
    for language, values in translations.items():
        assert set(values) == all_keys and all(values.values()), language
    assert {'raAccount', 'raUsername', 'raPassword', 'raLinked', 'raRestartRequired'} <= all_keys
    print('Dolphin account Build 267 source contracts: OK', flush=True)


def native():
    devices = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '-j']))['devices']
    candidates = [device for runtime, items in sorted(devices.items(), reverse=True)
                  if '.iOS-' in runtime for device in items if device['name'].startswith('iPhone') and device.get('isAvailable')]
    if not candidates:
        raise RuntimeError('An available iOS simulator is required for account-tap validation')
    with tempfile.TemporaryDirectory(prefix='dolphin-account-tests-') as folder:
        directory = Path(folder)
        (directory / 'main.m').write_text(APP)
        (directory / 'DolphinAccountTests.mm').write_text(TESTS)
        sdk_dependencies = [{'sdk': 'UIKit.framework'}, {'sdk': 'Foundation.framework'}, {'sdk': 'Security.framework'}]
        project = {
            'name': 'DolphinAccount267',
            'options': {'deploymentTarget': {'iOS': '17.4'}},
            'settings': {'base': {'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_ENABLE_MODULES': 'YES',
                                  'CODE_SIGNING_ALLOWED': 'NO', 'GENERATE_INFOPLIST_FILE': 'YES',
                                  'HEADER_SEARCH_PATHS': str(CLASSES)}},
            'targets': {
                'DolphinAccountHost': {'type': 'application', 'platform': 'iOS',
                    'sources': [str(directory / 'main.m'), str(CLASSES / 'DolphinSessionMenu.mm'),
                                str(CLASSES / 'DolphinRetroAchievementsAccount.mm')],
                    'dependencies': sdk_dependencies,
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.neostation.accounttests.host',
                        'INFOPLIST_KEY_UILaunchScreen_Generation': 'YES'}}},
                'DolphinAccountTests': {'type': 'bundle.unit-test', 'platform': 'iOS',
                    'sources': [str(directory / 'DolphinAccountTests.mm')],
                    'dependencies': [{'target': 'DolphinAccountHost'}] + sdk_dependencies,
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.neostation.accounttests.tests',
                        'TEST_HOST': '$(BUILT_PRODUCTS_DIR)/DolphinAccountHost.app/DolphinAccountHost',
                        'BUNDLE_LOADER': '$(TEST_HOST)'}}},
            },
            'schemes': {'DolphinAccount267': {'build': {'targets': {'DolphinAccountHost': 'all', 'DolphinAccountTests': 'test'}},
                                            'test': {'targets': ['DolphinAccountTests']}}},
        }
        spec = directory / 'project.json'
        spec.write_text(json.dumps(project))
        subprocess.run(['xcodegen', 'generate', '--spec', str(spec), '--project', str(directory)], check=True)
        result = ROOT / 'build/rpcs3-ci/DolphinAccount267.xcresult'
        result.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['xcodebuild', 'test', '-project', str(directory / 'DolphinAccount267.xcodeproj'),
            '-scheme', 'DolphinAccount267', '-destination', 'platform=iOS Simulator,id=' + candidates[0]['udid'],
            '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(result), 'CODE_SIGNING_ALLOWED=NO'], check=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--native', action='store_true')
    arguments = parser.parse_args()
    contracts()
    if arguments.native:
        native()
