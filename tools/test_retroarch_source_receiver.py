"""Compile the exact public RetroArch scene, with recording engine substitutes.

This is a UIKit transport experiment, not a RetroArch/TestFlight game test.
Upstream sources are pinned by commit AND Git blob identity. The unpatched
scene class is compiled verbatim; the fixed control applies the reviewed patch.
The legacy control models the documented pre-scene delegate lifecycle only.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import subprocess
import tempfile

from test_retroarch_uikit_handoff import run

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'test/fixtures/retroarch_handoff'
BEFORE = '875549ce5783dfb0f6fb94d0dc5b7fb115dad458'
INTRODUCED = '630b36bd774c873b73bfaa59183822837dbc9aac'
CURRENT = 'a7363feb909391c3217b91c30e81547e8208d6d5'
INPUTS = [
    (BEFORE, 'ui/drivers/ui_cocoatouch.m', '0cf1d8f3e0372d0170c6e98ca11eca94daf8b36f'),
    (BEFORE, 'pkg/apple/iOS/Info.plist', '46d83855da2e624784f87055ffb426b42f0102aa'),
    (INTRODUCED, 'ui/drivers/ui_cocoatouch.m', '25aa8231630b7f3164d1fb9014a5151e5b0dfa98'),
    (CURRENT, 'ui/drivers/ui_cocoatouch.m', '2e3b96c8e82f58b11a50819c889534b3f15ad1c0'),
    (CURRENT, 'pkg/apple/iOS/Info.plist', '3a8bcf64a25d44f313367a2536717ac40c1ecf2f'),
]

# All substituted behavior is below. This records receipt, supplies a window
# and makes lifecycle proxies no-ops. It never resolves or executes a game.
BOOTSTRAP = r'''
#import <UIKit/UIKit.h>
static void record(NSString *kind, id value) {
    NSURL *dir = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask] firstObject];
    NSURL *file = [dir URLByAppendingPathComponent:@"source-receiver.json"];
    NSData *old = [NSData dataWithContentsOfURL:file];
    NSMutableArray *events = old ? [[NSJSONSerialization JSONObjectWithData:old options:0 error:nil] mutableCopy] : [NSMutableArray new];
    [events addObject:@{@"event":kind, @"value":value}];
    [[NSJSONSerialization dataWithJSONObject:events options:NSJSONWritingPrettyPrinted error:nil] writeToURL:file atomically:YES];
}
@interface RetroArch_iOS : UIResponder <UIApplicationDelegate>
@property(nonatomic, retain) UIWindow *window;
+ (instancetype)get;
- (void)applicationDidBecomeActive:(UIApplication *)app;
- (void)applicationWillResignActive:(UIApplication *)app;
- (void)applicationDidEnterBackground:(UIApplication *)app;
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options;
@end
@implementation RetroArch_iOS
@synthesize window = _window;
+ (instancetype)get { return (RetroArch_iOS *)[UIApplication sharedApplication].delegate; }
- (void)setWindow:(UIWindow *)window {
    _window = window;
    _window.rootViewController = [UIViewController new];
    _window.rootViewController.view.backgroundColor = [UIColor greenColor];
}
- (void)applicationDidFinishLaunching:(UIApplication *)app {
    record(@"initialized", @YES);
    if (![[NSBundle mainBundle] objectForInfoDictionaryKey:@"UIApplicationSceneManifest"]) {
        self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        [self.window makeKeyAndVisible];
    }
}
- (void)applicationDidBecomeActive:(UIApplication *)app {}
- (void)applicationWillResignActive:(UIApplication *)app {}
- (void)applicationDidEnterBackground:(UIApplication *)app {}
- (BOOL)application:(UIApplication *)app openURL:(NSURL *)url options:(NSDictionary *)options {
    record(@"handler", url.absoluteString);
    return YES;
}
@end
'''
OBSERVER = r'''
// An observer outside the upstream class records what UIKit supplied.
@interface ObservedSceneDelegate : RetroArchSceneDelegate
@end
@implementation ObservedSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    NSMutableArray *urls = [NSMutableArray new];
    for (UIOpenURLContext *context in options.URLContexts) [urls addObject:context.URL.absoluteString];
    record(@"initialURLContexts", urls);
    [super scene:scene willConnectToSession:session options:options];
}
@end
'''
MAIN = r'''
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, @"RetroArch_iOS"); }
}
'''


def git_blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def read_inputs(cache):
    sources, identities = {}, []
    for ref, path, expected in INPUTS:
        local = cache / (ref + '-' + Path(path).name)
        if not local.exists():
            reply = json.loads(run('gh', 'api', f'repos/libretro/RetroArch/contents/{path}?ref={ref}'))
            local.write_bytes(base64.b64decode(reply['content']))
        data = local.read_bytes()
        assert git_blob(data) == expected, f'Unexpected upstream bytes: {ref}:{path}'
        sources[ref, path] = data.decode()
        identities.append({'commit': ref, 'path': path, 'blob': expected,
                           'sha256': hashlib.sha256(data).hexdigest()})
    return sources, identities


def scene(source):
    start = source.index('@interface RetroArchSceneDelegate')
    end = source.index('\n@end', source.index('@implementation RetroArchSceneDelegate', start)) + len('\n@end')
    return source[start:end]


def source_checks(sources, identities, out):
    before = sources[BEFORE, 'ui/drivers/ui_cocoatouch.m']
    current = sources[CURRENT, 'ui/drivers/ui_cocoatouch.m']
    license_header = current[:current.index('*/') + 2] + '\n'
    original_class = scene(current)
    assert original_class == scene(sources[INTRODUCED, 'ui/drivers/ui_cocoatouch.m'])
    assert 'RetroArchSceneDelegate' not in before
    assert 'applicationDidFinishLaunching:' in before
    before_plist = plistlib.loads(sources[BEFORE, 'pkg/apple/iOS/Info.plist'].encode())
    current_plist = plistlib.loads(sources[CURRENT, 'pkg/apple/iOS/Info.plist'].encode())
    assert 'UIApplicationSceneManifest' not in before_plist
    manifest = current_plist['UIApplicationSceneManifest']
    configs = manifest['UISceneConfigurations']['UIWindowSceneSessionRoleApplication']
    assert configs[0]['UISceneDelegateClassName'] == 'RetroArchSceneDelegate'
    for payload in [before_plist, current_plist]:
        assert any('retroarch' in x.get('CFBundleURLSchemes', []) for x in payload['CFBundleURLTypes'])
    out.mkdir(parents=True, exist_ok=True)
    (out / 'upstream-scene.m').write_text(license_header + original_class)
    with tempfile.TemporaryDirectory(prefix='retroarch-reviewed-patch-') as tmp:
        path = Path(tmp) / 'ui/drivers/ui_cocoatouch.m'
        path.parent.mkdir(parents=True)
        path.write_text(current)
        run('git', '-C', tmp, 'apply', '--check', str(ROOT / 'docs/upstream/retroarch-initial-scene-url.patch'))
        run('git', '-C', tmp, 'apply', str(ROOT / 'docs/upstream/retroarch-initial-scene-url.patch'))
        fixed_class = scene(path.read_text())
    assert fixed_class.count('[self scene:scene openURLContexts:initialURLs]') == 1
    (out / 'patched-scene.m').write_text(license_header + fixed_class)
    evidence = {'scope': 'public source and UIKit transport only; no TestFlight binary or cores',
                'inputs': identities, 'sceneUnchangedSince': INTRODUCED,
                'schemeUnchanged': True, 'patchAppliesToPinnedSource': True,
                'beforeUsesLegacyDelegate': True, 'cases': []}
    return license_header + original_class, license_header + fixed_class, manifest, evidence


def read_json(path, default=None):
    return json.loads(path.read_text()) if path.exists() else default


def simulator_controls(original, fixed, manifest, evidence, out):
    devices = json.loads(run('xcrun', 'simctl', 'list', 'devices', 'available', '-j'))['devices']
    sdk_ver = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version')
    runtime = 'com.apple.CoreSimulator.SimRuntime.iOS-' + sdk_ver.replace('.', '-')
    device = next(x for x in devices[runtime] if x.get('isAvailable') and 'iPhone' in x['name'])
    udid = run('xcrun', 'simctl', 'create', 'RetroArch source receiver control', device['deviceTypeIdentifier'], runtime)
    evidence.update({'runtime': runtime, 'deviceType': device['deviceTypeIdentifier'],
                     'xcode': run('xcodebuild', '-version'), 'gameExecutionValidated': False})
    try:
        run('xcrun', 'simctl', 'boot', udid)
        run('xcrun', 'simctl', 'bootstatus', udid, '-b')
        run('open', '-a', 'Simulator', '--args', '-CurrentDeviceUDID', udid)
        sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
        target = platform.machine() + '-apple-ios17.0-simulator'
        with tempfile.TemporaryDirectory(prefix='retroarch-source-uikit-') as tmp:
            tmp = Path(tmp)
            for mode, scene_source in [('legacy-control', ''), ('upstream-scenes', original), ('patched-scenes', fixed)]:
                print('Checking:', mode, flush=True)
                run('xcrun', 'simctl', 'terminate', udid, 'org.neostation.handofftest.receiver', check=False)
                run('xcrun', 'simctl', 'uninstall', udid, 'org.neostation.handofftest.receiver', check=False)
                run('xcrun', 'simctl', 'terminate', udid, 'org.neostation.handofftest.sender', check=False)
                run('xcrun', 'simctl', 'uninstall', udid, 'org.neostation.handofftest.sender', check=False)
                generated = tmp / 'Receiver.m'
                generated.write_text(BOOTSTRAP + '\n' + scene_source + ('\n' + OBSERVER if scene_source else '') + MAIN)
                targets = {}
                for name, scheme in [('Sender', 'neostation-handoff-test'), ('Receiver', 'retroarch')]:
                    bundle = tmp / (name + '.app')
                    bundle.mkdir(exist_ok=True)
                    info = {'CFBundleExecutable': name, 'CFBundleIdentifier': 'org.neostation.handofftest.' + name.lower(),
                            'CFBundleName': name, 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                            'CFBundleShortVersionString': '1', 'MinimumOSVersion': '17.0',
                            'UIDeviceFamily': [1, 2], 'LSRequiresIPhoneOS': True, 'UILaunchScreen': {},
                            'CFBundleURLTypes': [{'CFBundleURLSchemes': [scheme]}],
                            'CFBundleInfoDictionaryVersion': '6.0', 'CFBundleSupportedPlatforms': ['iPhoneSimulator'],
                            'LSApplicationQueriesSchemes': ['retroarch', 'neostation-handoff-test']}
                    if name == 'Receiver' and scene_source:
                        info['UIApplicationSceneManifest'] = json.loads(json.dumps(manifest))
                        info['UIApplicationSceneManifest']['UISceneConfigurations']['UIWindowSceneSessionRoleApplication'][0]['UISceneDelegateClassName'] = 'ObservedSceneDelegate'
                    (bundle / 'Info.plist').write_bytes(plistlib.dumps(info))
                    if name == 'Receiver':
                        sources = [str(generated)]
                        run('xcrun', 'clang', '-fobjc-arc', '-Werror', '-target', target, '-isysroot', sdk,
                            '-framework', 'UIKit', '-framework', 'Foundation', *sources, '-o', str(bundle / name))
                    else:
                        sources = [str(FIXTURE / 'Sender.swift'), str(FIXTURE / 'LegacyRetroArchURLHandoff.swift'),
                                   str(ROOT / 'packages/external_folder_access/ios/Classes/RetroArchURLHandoff.swift')]
                        run('xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-name', name,
                            '-target', target, '-sdk', sdk, *sources, '-o', str(bundle / name))
                    run('codesign', '--force', '--sign', '-', str(bundle))
                    run('xcrun', 'simctl', 'install', udid, str(bundle))
                    targets[name] = {'type': 'application', 'platform': 'iOS', 'sources': sources,
                                     'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': info['CFBundleIdentifier'],
                                                          'INFOPLIST_FILE': str(bundle / 'Info.plist')}}}
                targets['SourceReceiverTests'] = {'type': 'bundle.ui-testing', 'platform': 'iOS',
                    'sources': [str(FIXTURE / 'SourceReceiverTests.swift')], 'dependencies': [{'target': 'Sender'}],
                    'settings': {'base': {'PRODUCT_BUNDLE_IDENTIFIER': 'org.neostation.handofftest.source-tests',
                                         'GENERATE_INFOPLIST_FILE': 'YES', 'TEST_TARGET_NAME': 'Sender'}}}
                spec = {'name': 'SourceReceiver', 'options': {'deploymentTarget': {'iOS': '17.0'}},
                        'settings': {'base': {'SWIFT_VERSION': '5.0', 'CLANG_ENABLE_OBJC_ARC': 'YES',
                                             'CODE_SIGNING_ALLOWED': 'YES', 'CODE_SIGN_IDENTITY': '-'}},
                        'targets': targets, 'schemes': {'SourceReceiver': {
                            'build': {'targets': {'Sender': 'all', 'Receiver': 'all', 'SourceReceiverTests': 'test'}},
                            'test': {'targets': ['SourceReceiverTests']}}}}
                spec_path = tmp / 'project.json'
                spec_path.write_text(json.dumps(spec))
                run('xcodegen', 'generate', '--spec', str(spec_path), '--project', str(tmp))
                log = run('xcodebuild', 'test', '-project', str(tmp / 'SourceReceiver.xcodeproj'), '-scheme', 'SourceReceiver',
                          '-destination', 'platform=iOS Simulator,id=' + udid, '-parallel-testing-enabled', 'NO',
                          'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'DEVELOPMENT_TEAM=',
                          '-resultBundlePath', str(out / (mode + '.xcresult')),
                          '-only-testing:SourceReceiverTests/SourceReceiverTests/testSupportedRoutesColdThenWarm', timeout=480)
                (out / (mode + '.log')).write_text(log)
                sender_data = Path(run('xcrun', 'simctl', 'get_app_container', udid, 'org.neostation.handofftest.sender', 'data')) / 'Documents'
                receiver_data = Path(run('xcrun', 'simctl', 'get_app_container', udid, 'org.neostation.handofftest.receiver', 'data')) / 'Documents'
                events = read_json(receiver_data / 'source-receiver.json', [])
                deliveries = [x['value'] for x in events if x['event'] == 'handler']
                initials = [x['value'] for x in events if x['event'] == 'initialURLContexts']
                case = {'mode': mode, 'receiver': events, 'sender': [], 'routes': []}
                for index, host in enumerate(['game', 'library', 'topshelf']):
                    sender_events = read_json(sender_data / f'result-source-{index}.json')
                    sends = [x for x in sender_events if x['event'] == 'send']
                    assert len(sends) == 2 and sends[0]['url'] == sends[1]['url']
                    assert all(x['state'] == 0 for x in sends)
                    assert [x['accepted'] for x in sender_events if x['event'] == 'finished'] == [True, True]
                    url = sends[0]['url']
                    expected = 1 if mode == 'upstream-scenes' else 2
                    assert deliveries.count(url) == expected, (mode, host, deliveries)
                    if scene_source:
                        assert [url] in initials, (mode, host, initials)
                    case['sender'].append(sender_events)
                    case['routes'].append({'host': host, 'url': url, 'accepted': 2,
                                           'received': expected, 'coldReceived': mode != 'upstream-scenes',
                                           'warmReceived': True})
                assert len(deliveries) == (3 if mode == 'upstream-scenes' else 6), deliveries
                evidence['cases'].append(case)
                (out / 'source-receiver-evidence.json').write_text(json.dumps(evidence, indent=2))
                print(mode, ':', [(x['host'], x['received']) for x in case['routes']], flush=True)
    finally:
        run('xcrun', 'simctl', 'shutdown', udid, check=False)
        run('xcrun', 'simctl', 'delete', udid, check=False)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source-cache', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--source-check-only', action='store_true')
    args = parser.parse_args()
    cache = args.source_cache or args.output / 'source-cache'
    cache.mkdir(parents=True, exist_ok=True)
    sources, identities = read_inputs(cache)
    original, fixed, manifest, evidence = source_checks(sources, identities, args.output)
    (args.output / 'source-identity.json').write_text(json.dumps(evidence, indent=2))
    if not args.source_check_only:
        simulator_controls(original, fixed, manifest, evidence, args.output)
    print('Upstream source identities and receiver patch verified; game execution is not validated.')


if __name__ == '__main__':
    main()
