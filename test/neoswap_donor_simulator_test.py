#!/usr/bin/env python3
"""Real iOS 18 Simulator donor launch and NeoSwap ABI 1 allocation proof.

No mocked Foundation, fake child PID, entitlement inference, or skipped runtime
failure. Creates and removes only its own app/extension and simulator device.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
DONATION = ROOT / 'native/neoswap-donation'
HOST = ROOT / 'packages/neo_swap/ios/Classes'
BUNDLE = 'com.neogamelab.neostation.neoswap-simulator-proof'
LOGS: list[str] = []

HARNESS = r'''
#import <UIKit/UIKit.h>
#import "NeoSwapDonorIPC.h"
#include "Broker.h"
#include "Pool.h"
#include "NeoSwap.h"
#include "NeoSwapHost.h"
#include <cstring>
#include <atomic>
#include <unistd.h>

namespace {
constexpr uint64_t MiB = 1024 * 1024;
std::atomic<bool> completed{false};
NSString* reportPath() {
  NSString* documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [documents stringByAppendingPathComponent:@"donation-simulator.json"];
}
void finish(NSDictionary* report) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (completed) return;
    completed = true;
    NSData* data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:reportPath() atomically:YES];
    NSLog(@"NEOSWAP_SIMULATOR_PROOF %@", report);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
  });
}
void fail(NSString* stage, NSString* detail, NSDictionary* diagnostics) {
  finish(@{@"schema":@1, @"passed":@NO, @"stage":stage, @"technicalError":detail,
           @"diagnostics":diagnostics ?: @{}, @"physicalIphoneValidated":@NO});
}
NSString* ownedHelper() {
  NSArray* entries = [NSFileManager.defaultManager contentsOfDirectoryAtURL:NSBundle.mainBundle.builtInPlugInsURL
                                              includingPropertiesForKeys:nil options:0 error:nil];
  NSString* ownPrefix = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@"."];
  NSString* found = nil;
  for (NSURL* entry in entries) {
    if (![entry.pathExtension isEqual:@"appex"]) continue;
    NSBundle* bundle = [NSBundle bundleWithURL:entry];
    NSDictionary* extension = [bundle objectForInfoDictionaryKey:@"NSExtension"];
    if ([[bundle objectForInfoDictionaryKey:@"NeoStationNeoSwapDonor"] isEqual:@"1"] &&
        [extension[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.share-services"] &&
        [bundle.bundleIdentifier hasPrefix:ownPrefix]) {
      if (found) return nil;
      found = bundle.bundleIdentifier;
    }
  }
  return found;
}
}

@interface ProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) NeoSwapDonorSession* donor;
@end
@implementation ProbeApp {
  BOOL _adopted;
  BOOL _closing;
  void* _loan;
  uint64_t _capacity;
  uint64_t _resident;
  uint64_t _compressed;
  int32_t _pid;
  NSDictionary* _verifiedDiagnostics;
}
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  (void)application; (void)options;
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  UIViewController* controller = [UIViewController new];
  controller.view.backgroundColor = UIColor.blackColor;
  self.window.rootViewController = controller;
  [self.window makeKeyAndVisible];
  NSString* helper = ownedHelper();
  if (!helper) { fail(@"owned_helper_discovery", @"Dedicated own marker/bundle helper was not found", nil); return YES; }
  NSString* cache = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"NeoSwapDonorProof"];
  [NSFileManager.defaultManager createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
  NeoSwapConfig config{sizeof(NeoSwapConfig), NEOSWAP_ABI, 128 * MiB, 0, MiB, 1u << NEOSWAP_RPCS3, 0};
  const int configured = NeoSwap_Configure(cache.fileSystemRepresentation, &config);
  if (configured != NEOSWAP_OK) {
    fail(@"neoswap_configure", [NSString stringWithFormat:@"NeoSwap_Configure=%d", configured], nil);
    return YES;
  }
  __weak ProbeApp* weakSelf = self;
  self.donor = [[NeoSwapDonorSession alloc] initWithHelperIdentifier:helper requestedBytes:64 * MiB
      generation:1 timeout:12 observer:^(NeoSwapDonorSession* source, NeoSwapDonorSnapshot snapshot, NSError* error) {
    ProbeApp* self = weakSelf;
    if (!self || completed) return;
    if (snapshot.state == NeoSwapDonorStateFailed) {
      neostation::donation::pool_lost(snapshot.generation, snapshot.kernelResult);
      fail(@"real_extension_donation", error.localizedDescription ?: @"Native donor failed", source.diagnostics);
      return;
    }
    if (snapshot.state == NeoSwapDonorStateActive && !self->_adopted) {
      if (snapshot.donorPID <= 0 || snapshot.donorPID == getpid() || snapshot.capacityBytes < MiB ||
          snapshot.donatedResidentBytes + snapshot.donatedCompressedBytes <
              snapshot.capacityBytes - MIN(MiB, snapshot.capacityBytes / 16)) {
        fail(@"donor_kernel_accounting", @"A separate PID and real kernel charged pages were not established", source.diagnostics);
        return;
      }
      auto begun = neostation::donation::pool_begin(snapshot.generation, snapshot.donorPID, 128 * MiB);
      mach_port_t right = [source copyMemoryEntry];
      if (!begun || !right) {
        fail(@"pool_begin_copy_right", @"Verified session could not prepare an independently mapped pool", source.diagnostics);
        return;
      }
      auto adopted = neostation::donation::pool_adopt(snapshot.generation, right, snapshot.capacityBytes);
      mach_port_deallocate(mach_task_self(), right);
      neostation::donation::Footprint footprint{};
      footprint.physical = snapshot.donorFootprintBytes;
      footprint.nonvolatile = snapshot.donorNonvolatileBytes;
      footprint.nonvolatile_compressed = snapshot.donorCompressedBytes;
      auto verified = adopted ? neostation::donation::pool_verified(snapshot.generation, footprint) : adopted;
      if (!verified) {
        fail(@"pool_adopt_verify", [NSString stringWithFormat:@"%s/%d",
             neostation::donation::stage_name(verified.stage), verified.kernel_result], source.diagnostics);
        return;
      }
      const NeoSwapAPI* api = NeoSwap_GetAPI(NEOSWAP_ABI);
      const int allocated = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, MiB, 65536, &self->_loan);
      NeoSwapHostStats host{};
      NeoSwap_HostSnapshot(&host);
      NeoSwapStats stats{}; stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_ABI;
      NeoSwap_Snapshot(&stats);
      if (allocated != NEOSWAP_OK || !self->_loan || host.donated_live_bytes != MiB ||
          stats.allocated_disk_bytes != 0 || stats.live_bytes != MiB) {
        fail(@"neoswap_abi1_real_donation_route", [NSString stringWithFormat:
             @"allocate=%d donated=%llu disk=%llu live=%llu", allocated,
             (unsigned long long)host.donated_live_bytes, (unsigned long long)stats.allocated_disk_bytes,
             (unsigned long long)stats.live_bytes], source.diagnostics);
        return;
      }
      std::memset(self->_loan, 0x5a, MiB);
      if (api->sync(self->_loan) != NEOSWAP_OK) {
        fail(@"donation_sync", @"The donated ABI1 loan could not be synchronized", source.diagnostics);
        return;
      }
      self->_adopted = YES;
      self->_capacity = snapshot.capacityBytes;
      self->_resident = snapshot.donatedResidentBytes;
      self->_compressed = snapshot.donatedCompressedBytes;
      self->_pid = snapshot.donorPID;
      self->_verifiedDiagnostics = source.diagnostics;
      self->_closing = YES;
      [source close];
    } else if (snapshot.state == NeoSwapDonorStateClosed && self->_closing) {
      if (error || [source.diagnostics[@"cleanupPending"] isEqual:@YES]) {
        fail(@"donor_mapping_cleanup", error.localizedDescription ?: @"Mapping cleanup remains pending", source.diagnostics);
        return;
      }
      neostation::donation::pool_lost(snapshot.generation, 0);
      for (uint64_t offset = 0; offset < MiB; ++offset) {
        if (static_cast<const unsigned char*>(self->_loan)[offset] != 0x5a) {
          fail(@"retained_data_after_donor_close", @"Existing donated pointer lost its contents", source.diagnostics);
          return;
        }
      }
      void* forbidden = nullptr;
      uint64_t token = 0;
      auto direct = neostation::donation::pool_acquire(MiB, 65536, &forbidden, &token);
      if (direct || forbidden || token) {
        fail(@"new_donor_loans_after_close", @"Disconnected donor still offered a new pool loan", source.diagnostics);
        return;
      }
      const NeoSwapAPI* api = NeoSwap_GetAPI(NEOSWAP_ABI);
      void* fallback = nullptr;
      const int allocated = api->allocate(NEOSWAP_RPCS3, NEOSWAP_CPU_DATA, MiB, 65536, &fallback);
      NeoSwapHostStats host{}; NeoSwap_HostSnapshot(&host);
      NeoSwapStats stats{}; stats.struct_size = sizeof(stats); stats.abi_version = NEOSWAP_ABI; NeoSwap_Snapshot(&stats);
      if (allocated != NEOSWAP_OK || !fallback || host.donated_live_bytes != MiB ||
          stats.allocated_disk_bytes < MiB) {
        fail(@"file_fallback_after_donor_close", @"The explicit file-backed fallback did not preserve the existing donated loan", source.diagnostics);
        return;
      }
      const int releasedFallback = api->release(fallback);
      const int releasedLoan = api->release(self->_loan);
      self->_loan = nullptr;
      NeoSwap_HostSnapshot(&host);
      if (releasedFallback != NEOSWAP_OK || releasedLoan != NEOSWAP_OK || host.donated_live_bytes) {
        fail(@"donated_and_file_release", @"ABI1 did not release both independent allocation kinds", source.diagnostics);
        return;
      }
      finish(@{@"schema":@1, @"passed":@YES, @"platform":@"iOS18Simulator",
               @"transport":@"real-NSExtension-auxiliary-NSXPC", @"realIPhoneValidated":@NO,
               @"physicalIphoneValidated":@NO, @"hostPID":@(getpid()), @"donorPID":@(self->_pid),
               @"capacityBytes":@(self->_capacity), @"donorResidentBytes":@(self->_resident),
               @"donorCompressedBytes":@(self->_compressed), @"abiVersion":@(NEOSWAP_ABI),
               @"realDonationLoanBytes":@(MiB), @"donationDiskBytes":@0,
               @"retainedDataAfterClose":@YES, @"newLoansBlockedAfterClose":@YES,
               @"explicitFileFallbackPassed":@YES, @"releasePassed":@YES,
               @"diagnostics":self->_verifiedDiagnostics ?: @{}});
    }
  }];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self.donor start]; });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    if (!completed) fail(@"app_harness_deadline", @"The real extension or allocator lifecycle did not finish", self.donor.diagnostics);
  });
  return YES;
}
@end
int main(int argc, char* argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApp.class)); }
}
'''


def run(arguments: list[str], *, timeout: int = 60, capture: bool = False) -> str:
    try:
        result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as error:
        output = error.stdout or ''
        if isinstance(output, bytes):
            output = output.decode(errors='replace')
        LOGS.append('COMMAND ' + ' '.join(arguments) + '\nTIMEOUT\n' + output)
        raise
    LOGS.append('COMMAND ' + ' '.join(arguments) + '\n' + (result.stdout or ''))
    if not capture and result.stdout:
        print(result.stdout)
    result.check_returncode()
    return result.stdout or ''


def sdk_runtime() -> tuple[str, str]:
    runtimes = json.loads(run(['xcrun', 'simctl', 'list', 'runtimes', '--json'], capture=True))['runtimes']
    candidates = [runtime for runtime in runtimes if runtime.get('isAvailable') and
                  runtime.get('version', '').split('.')[0] == '18' and
                  'SimRuntime.iOS-' in runtime['identifier']]
    if not candidates:
        raise RuntimeError('Required real iOS 18 Simulator runtime is unavailable; runtime proof is not skipped')
    runtime = sorted(candidates, key=lambda item: tuple(map(int, item['version'].split('.'))))[-1]
    sdk = run(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path'], capture=True).strip()
    return sdk, runtime['identifier']


def plist(path: Path, value: dict) -> None:
    path.write_bytes(plistlib.dumps(value))


def build(work: Path, sdk: str) -> tuple[Path, dict[str, str]]:
    app = work / 'NeoSwapSimulator.app'
    helper = app / 'PlugIns/NeoSwapDonor.appex'
    helper.mkdir(parents=True)
    simulator_host = work / 'SimulatorHost.mm'
    simulator_host.write_text(HARNESS)
    # The exact canonical C ABI broker is copied unchanged to give its Donation/
    # include a canonical namespace without depending on generated pod files.
    abi = work / 'CanonicalABI'
    abi.mkdir()
    for name in ('NeoSwap.cpp', 'NeoSwap.h', 'NeoSwapHost.h'):
        shutil.copyfile(HOST / name, abi / name)
    (abi / 'Donation').symlink_to(DONATION, target_is_directory=True)
    architecture = platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise RuntimeError(f'Unsupported Simulator runner architecture: {architecture}')
    common = ['xcrun', '--sdk', 'iphonesimulator', 'clang++', '-x', 'objective-c++', '-std=c++20',
              '-O1', '-g', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
              '-isysroot', sdk, '-target', f'{architecture}-apple-ios18.0-simulator',
              '-I', str(DONATION), '-I', str(abi), '-framework', 'Foundation',
              '-framework', 'UIKit', '-framework', 'Security']
    host_sources = [DONATION / name for name in
                    ('Broker.cpp', 'Pool.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorIPC.mm')]
    host_sources += [abi / 'NeoSwap.cpp', simulator_host]
    helper_sources = [DONATION / name for name in
                      ('Broker.cpp', 'NeoSwapMachHandle.mm', 'NeoSwapDonorRequestHandler.mm')]
    run(common + ['-DNEOSWAP_DONATION=1'] + list(map(str, host_sources)) + ['-o', str(app / 'NeoSwapSimulator')], timeout=120)
    run(common + ['-fapplication-extension', '-Wl,-e,_NSExtensionMain'] + list(map(str, helper_sources)) +
        ['-o', str(helper / 'NeoSwapDonor')], timeout=120)
    info = {'CFBundleIdentifier':BUNDLE, 'CFBundleExecutable':'NeoSwapSimulator',
            'CFBundleName':'NeoSwapSimulator', 'CFBundlePackageType':'APPL',
            'CFBundleVersion':'1', 'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'18.0',
            'UIDeviceFamily':[1, 2], 'UILaunchScreen':{},
            'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait']}
    plist(app / 'Info.plist', info)
    helper_info = plistlib.loads((DONATION / 'Info.plist').read_bytes())
    helper_info.update({'CFBundleIdentifier':BUNDLE + '.neoswapdonor', 'CFBundleExecutable':'NeoSwapDonor',
                        'CFBundleName':'NeoSwapDonor', 'CFBundleVersion':'1',
                        'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'18.0'})
    plist(helper / 'Info.plist', helper_info)
    entitlements = DONATION / 'NeoSwapDonor.entitlements'
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(helper)])
    host_entitlements = work / 'host.entitlements'
    plist(host_entitlements, {'get-task-allow':True})
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(host_entitlements), str(app)])
    source_files = [DONATION / name for name in ('Broker.cpp', 'Broker.h', 'Pool.cpp', 'Pool.h',
                    'NeoSwapMachHandle.mm', 'NeoSwapMachHandle.h', 'NeoSwapDonorIPC.mm', 'NeoSwapDonorIPC.h',
                    'NeoSwapDonorRequestHandler.mm', 'NeoSwapDonorRequestHandler.h', 'Info.plist',
                    'NeoSwapDonor.entitlements')]
    source_files += [HOST / name for name in ('NeoSwap.cpp', 'NeoSwap.h', 'NeoSwapHost.h')]
    hashes = {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest() for path in source_files}
    return app, hashes


def main() -> int:
    parser = argparse.ArgumentParser()
    destination = parser.add_mutually_exclusive_group(required=True)
    destination.add_argument('--report', type=Path)
    destination.add_argument('--output', type=Path)
    args = parser.parse_args()
    output = args.output or args.report.parent
    report_path = args.report or (output / 'report.json')
    report = {'schema':1, 'passed':False, 'platform':'iOS18Simulator',
              'realIPhoneValidated':False, 'physicalIphoneValidated':False}
    identifier: str | None = None
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('A real Apple Simulator runner is required; this proof is not mocked or skipped')
        sdk, runtime = sdk_runtime()
        with tempfile.TemporaryDirectory(prefix='neoswap-donor-simulator-') as directory:
            app, hashes = build(Path(directory), sdk)
            report.update({'runtime':runtime, 'sourceSHA256':hashes})
            device_types = json.loads(run(['xcrun', 'simctl', 'list', 'devicetypes', '--json'], capture=True))['devicetypes']
            matches = [item for item in device_types if item['identifier'] == 'com.apple.CoreSimulator.SimDeviceType.iPhone-16']
            if not matches:
                raise RuntimeError('iPhone 16 Simulator device type is unavailable')
            identifier = run(['xcrun', 'simctl', 'create', 'NeoSwapDonorProof', matches[0]['identifier'], runtime], capture=True).strip()
            run(['xcrun', 'simctl', 'boot', identifier])
            run(['xcrun', 'simctl', 'bootstatus', identifier, '-b'], timeout=180)
            run(['xcrun', 'simctl', 'install', identifier, str(app)], timeout=90)
            launched = run(['xcrun', 'simctl', 'launch', '--console', '--terminate-running-process',
                            identifier, BUNDLE], capture=True, timeout=45)
            print(launched[-20000:])
            container = Path(run(['xcrun', 'simctl', 'get_app_container', identifier, BUNDLE, 'data'], capture=True).strip())
            evidence = container / 'Documents/donation-simulator.json'
            if not evidence.is_file():
                raise RuntimeError('Actual Simulator app did not produce extension/allocator proof; launch output: ' + launched[-12000:])
            report.update(json.loads(evidence.read_text()))
            if not report.get('passed'):
                raise RuntimeError('Actual extension donation failed: ' + json.dumps(report, ensure_ascii=False))
            print(json.dumps(report, indent=2, ensure_ascii=False))
            return 0
    except (OSError, RuntimeError, subprocess.SubprocessError) as exception:
        report['passed'] = False
        report['runnerError'] = str(exception)
        print(str(exception), file=sys.stderr)
        if identifier:
            try:
                logs = run(['xcrun', 'simctl', 'spawn', identifier, 'log', 'show', '--last', '2m',
                            '--style', 'compact', '--predicate',
                            'process == "NeoSwapDonor" OR process == "NeoSwapSimulator"'], capture=True, timeout=20)
                report['simulatorLogs'] = logs[-30000:]
            except subprocess.SubprocessError as log_error:
                report['simulatorLogError'] = str(log_error)
        return 1
    finally:
        report_path.parent.mkdir(parents=True, exist_ok=True)
        report_path.write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n')
        if identifier:
            for action in ('shutdown', 'delete'):
                try:
                    run(['xcrun', 'simctl', action, identifier], capture=True, timeout=20)
                except subprocess.SubprocessError as cleanup_error:
                    print(f'Own Simulator {action} failed: {cleanup_error}', file=sys.stderr)
        output.mkdir(parents=True, exist_ok=True)
        (output / 'runner.log').write_text('\n'.join(LOGS))


if __name__ == '__main__':
    raise SystemExit(main())
