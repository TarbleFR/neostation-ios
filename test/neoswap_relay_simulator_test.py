#!/usr/bin/env python3
"""Actual iOS 18 extension exit and retained-page alias lifecycle proof.

Foundation IPC and the canonical Backend are real. A Simulator result never
claims device jetsam behavior, physical iPhone RAM, or RPCS3 gameplay.
"""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import platform
import plistlib
import shutil
import struct
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
RELAY = ROOT / 'native/neoswap-relay'
DONATION = ROOT / 'native/neoswap-donation'
PUBLIC = ROOT / 'packages/neo_swap/ios/Classes'
BUNDLE = 'com.neogamelab.neostation.relay-simulator-proof'
TARGET_BYTES = 32 * 1024**2
sys.path.insert(0, str(ROOT / 'build-utils'))
from configure_neoswap_relay import RELAY_CONTRACT, REQUIRED_RELAY_ENTITLEMENTS, materialize
from embed_rpcs3_host_entitlements import embedded_entitlements, require_entitlements
from neoswap_donor_simulator_test import (LOGS, run, sdk_runtime, collect_launch_evidence,
                                         plist, simulator_executable)

HARNESS = r'''
#import <UIKit/UIKit.h>
#import "NeoSwapPageRelay.h"
#import "NeoSwapRelayService.h"
#include "Backend.h"
#include "Broker.h"
#include <atomic>
#include <cstring>
#include <mach/mach.h>
#include <unistd.h>

namespace {
constexpr uint64_t target = 32ULL * 1024 * 1024;
std::atomic<bool> finished{false};
void finish(NSDictionary* result) {
  if (finished.exchange(true)) return;
  dispatch_async(dispatch_get_main_queue(), ^{
    NSString* directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[directory stringByAppendingPathComponent:@"relay-simulator.json"] atomically:YES];
    NSLog(@"NEOSWAP_RELAY_SIMULATOR %@", result);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ exit(0); });
  });
}
void fail(NSString* stage, NSDictionary* details) {
  finish(@{@"schema":@1, @"passed":@NO, @"stage":stage, @"diagnostics":details ?: @{},
           @"platform":@"iOS18Simulator", @"realIPhoneValidated":@NO,
           @"realRPCS3GameplayValidated":@NO});
}
bool allBytes(const void* address, unsigned char pattern) {
  const auto* p = static_cast<const unsigned char*>(address);
  for (uint64_t index = 0; index < target; ++index) if (p[index] != pattern) return false;
  return true;
}
bool isReadOnly(void* address) {
  vm_address_t current = reinterpret_cast<vm_address_t>(address);
  vm_size_t bytes = 0;
  vm_region_basic_info_data_64_t info{};
  mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
  mach_port_t object = MACH_PORT_NULL;
  kern_return_t result = vm_region_64(mach_task_self(), &current, &bytes, VM_REGION_BASIC_INFO_64,
      reinterpret_cast<vm_region_info_t>(&info), &count, &object);
  if (object) mach_port_deallocate(mach_task_self(), object);
  return result == KERN_SUCCESS && current == reinterpret_cast<vm_address_t>(address) &&
      bytes >= target && info.protection == VM_PROT_READ;
}
}
@interface RelayProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@property(nonatomic, strong) NeoSwapPageRelaySession* session;
@property(nonatomic, strong) NSMutableDictionary* evidence;
- (void)prepare:(uint64_t)generation;
- (void)exerciseManager;
- (void)exercise:(NSArray<NeoSwapPageRelayHandle*>*)handles pid:(int32_t)pid generation:(uint64_t)generation;
@end
@implementation RelayProbeApp
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  (void)application; (void)options;
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [UIViewController new];
  [self.window makeKeyAndVisible];
  self.evidence = [@{@"schema":@1, @"platform":@"iOS18Simulator",
      @"transport":@"real-NSExtension-auxiliary-NSXPC", @"realIPhoneValidated":@NO,
      @"realRPCS3GameplayValidated":@NO, @"hostPID":@(getpid())} mutableCopy];
  [self prepare:1];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    fail(@"runtime_deadline", self.session.diagnostics);
  });
  return YES;
}
- (void)prepare:(uint64_t)generation {
  if (neostation::relay::configure(1, target) != NEOSWAP_RELAY_OK) {
    fail(@"backend_configure", nil); return;
  }
  NSString* helper = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".NeoSwapPageRelay"];
  __weak RelayProbeApp* weak = self;
  self.session = [[NeoSwapPageRelaySession alloc] initWithHelperIdentifier:helper requestedBytes:target
      generation:generation timeout:25 completion:^(NSArray<NeoSwapPageRelayHandle*>* handles,
      int32_t pid, uint64_t completedGeneration, NSError* error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      RelayProbeApp* app = weak;
      if (!app || finished.load()) return;
      if (error || completedGeneration != generation || pid <= 0 || pid == getpid()) {
        fail(@"authenticated_creator_exit", @{@"error":error.description ?: @"invalid completion",
                                             @"session":app.session.diagnostics}); return;
      }
      [app exercise:handles pid:pid generation:generation];
    });
  }];
  [self.session start];
}
- (void)exercise:(NSArray<NeoSwapPageRelayHandle*>*)handles pid:(int32_t)pid generation:(uint64_t)generation {
  const NeoSwapRelayAPI* api = NeoSwap_GetRelayAPI(NEOSWAP_RELAY_ABI);
  NSDictionary* diagnostics = self.session.diagnostics;
  if (!api || api->abi_version != 1 || ![diagnostics[@"creatorExitObserved"] isEqual:@YES] ||
      ![diagnostics[@"exitEvidence"] isEqual:@"kernel_dispatch_proc_exit"]) {
    fail(@"kernel_exit_required_before_adoption", diagnostics); return;
  }
  uint64_t total = 0;
  for (NeoSwapPageRelayHandle* handle in handles) {
    if (neostation::relay::adopt(handle.memoryEntry, handle.capacityBytes, pid, generation) != NEOSWAP_RELAY_OK) {
      fail(@"retain_named_entry_after_creator_exit", diagnostics); return;
    }
    total += handle.capacityBytes;
  }
  if (total != target) { fail(@"exact_capacity", diagnostics); return; }
  uint64_t token = 0;
  void* first = nullptr;
  void* second = nullptr;
  if (api->create(0, target, &token) != NEOSWAP_RELAY_OK || !token ||
      api->map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &first) != NEOSWAP_RELAY_OK ||
      api->map(token, nullptr, NEOSWAP_RELAY_READ, &second) != NEOSWAP_RELAY_OK ||
      !first || !second || first == second ||
      reinterpret_cast<uintptr_t>(first) % NEOSWAP_RELAY_ALIGNMENT ||
      reinterpret_cast<uintptr_t>(second) % NEOSWAP_RELAY_ALIGNMENT) {
    fail(@"two_distinct_aliases_same_backing", diagnostics); return;
  }
  neostation::donation::Footprint before{}, during{};
  if (!neostation::donation::footprint(before)) { fail(@"actual_host_ledger_before_write", nil); return; }
  std::memset(first, 0xa7, target);
  bool coherent = allBytes(second, 0xa7);
  std::memset(first, 0x5c, target);
  coherent = coherent && allBytes(second, 0x5c);
  bool readOnly = isReadOnly(second);
  bool busy = api->release(token) == NEOSWAP_RELAY_BUSY;
  NeoSwapRelayStats live{}; live.struct_size = sizeof(live);
  if (!coherent || !readOnly || !busy || api->snapshot(&live) != NEOSWAP_RELAY_OK ||
      live.capacity_bytes != target || live.live_bytes != target || live.alias_count != 2 ||
      live.mapped_alias_bytes != 2 * target || !neostation::donation::footprint(during)) {
    fail(@"written_alias_coherence_readonly_and_busy_release", diagnostics); return;
  }
  if (api->unmap(token, second) != NEOSWAP_RELAY_OK || api->unmap(token, first) != NEOSWAP_RELAY_OK ||
      api->release(token) != NEOSWAP_RELAY_OK || api->release(token) != NEOSWAP_RELAY_UNKNOWN) {
    fail(@"release_and_stale_token", diagnostics); return;
  }
  uint64_t reused = 0;
  void* zeroed = nullptr;
  if (api->create(0, target, &reused) != NEOSWAP_RELAY_OK || !reused || reused == token ||
      api->map(reused, nullptr, NEOSWAP_RELAY_READ, &zeroed) != NEOSWAP_RELAY_OK ||
      !allBytes(zeroed, 0) || api->unmap(reused, zeroed) != NEOSWAP_RELAY_OK ||
      api->release(reused) != NEOSWAP_RELAY_OK) {
    fail(@"scrub_before_interval_reuse", diagnostics); return;
  }
  NeoSwapRelayStats retired{}; retired.struct_size = sizeof(retired);
  if (api->snapshot(&retired) != NEOSWAP_RELAY_OK || retired.live_bytes || retired.alias_count ||
      retired.retained_capacity_bytes != target || neostation::relay::shutdown() != NEOSWAP_RELAY_OK) {
    fail(@"retire_released_objects", diagnostics); return;
  }
  NeoSwapRelayStats ended{}; ended.struct_size = sizeof(ended);
  if (api->snapshot(&ended) != NEOSWAP_RELAY_OK || ended.capacity_bytes || ended.retained_capacity_bytes ||
      ended.pending_cleanup_entries || ended.live_bytes || ended.alias_count) {
    fail(@"retire_every_mapping_and_send_right", diagnostics); return;
  }
  if (generation == 1) {
    [self.evidence addEntriesFromDictionary:@{@"creatorPID":@(pid), @"generation":@1,
        @"creatorExitObserved":@YES, @"firstCreatorExitObserved":@YES,
        @"capacityBytes":@(target), @"writtenBytes":@(target), @"aliasCountDuringUse":@(live.alias_count),
        @"liveBytesDuringUse":@(live.live_bytes), @"aliasedBytesDuringUse":@(live.mapped_alias_bytes),
        @"retainedBytesAfterRelease":@(retired.retained_capacity_bytes),
        @"liveBytesAfterRelease":@(retired.live_bytes), @"capacityBytesAfterShutdown":@(ended.capacity_bytes),
        @"pendingCleanupAfterShutdown":@(ended.pending_cleanup_entries),
        @"aliasCoherencePassed":@(coherent), @"readOnlyAliasPassed":@(readOnly),
        @"releaseWhileMappedRefused":@(busy), @"staleTokenRefused":@YES,
        @"releaseZeroingPassed":@YES, @"releasePassed":@YES,
        @"hostPhysicalBeforeWrite":@(before.physical), @"hostPhysicalAfterWrite":@(during.physical),
        @"hostNonvolatileBeforeWrite":@(before.nonvolatile), @"hostNonvolatileAfterWrite":@(during.nonvolatile),
        @"firstSession":diagnostics}];
    self.session = nil;
    [self prepare:2];
  } else {
    if ([self.evidence[@"creatorPID"] intValue] == pid) { fail(@"fresh_creator_process", diagnostics); return; }
    [self.evidence addEntriesFromDictionary:@{@"secondCreatorPID":@(pid), @"secondGeneration":@(generation),
        @"secondCreatorExitObserved":@YES, @"secondPreparationPassed":@YES,
        @"secondSession":diagnostics, @"passed":@YES}];
    [self exerciseManager];
  }
}
- (void)exerciseManager {
  self.session = nil;
  CFAbsoluteTime started = CFAbsoluteTimeGetCurrent();
  NeoSwapRelay_Start();
  (void)NeoSwapRelay_WaitReady(10000);
  if (CFAbsoluteTimeGetCurrent() - started > 0.5) {
    fail(@"production_manager_must_not_block_main_thread", nil); return;
  }
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    int ready = NeoSwapRelay_WaitReady(10000);
    if (ready != NEOSWAP_RELAY_OK) ready = NeoSwapRelay_WaitReady(10000);
    NSDictionary* diagnostics = NeoSwapRelay_Diagnostics();
    NSDictionary* capability = diagnostics[@"capabilityCheck"];
    const NeoSwapRelayAPI* api = NeoSwap_GetRelayAPI(1);
    if (ready != NEOSWAP_RELAY_OK || ![diagnostics[@"ready"] isEqual:@YES] ||
        ![diagnostics[@"creatorExitObserved"] isEqual:@YES] ||
        [diagnostics[@"capacityBytes"] unsignedLongLongValue] != 8ULL * 1024 * 1024 * 1024 ||
        [capability[@"requestedBytes"] unsignedLongLongValue] != 16ULL * 1024 * 1024 ||
        ![capability[@"aliasDataVerified"] isEqual:@YES] || [capability[@"result"] intValue] != 0 ||
        !api || api->enabled(0) != 1) {
      fail(@"production_manager_prepare_capability_and_enable_rpcs3", diagnostics); return;
    }
    for (uint32_t owner = 1; owner < 6; ++owner) if (api->enabled(owner)) {
      fail(@"production_manager_initial_owner_scope", diagnostics); return;
    }
    uint64_t token = 0;
    void* writer = nullptr;
    void* reader = nullptr;
    if (api->create(0, target, &token) != 0 || api->map(token, nullptr, NEOSWAP_RELAY_READ_WRITE, &writer) != 0 ||
        api->map(token, nullptr, NEOSWAP_RELAY_READ, &reader) != 0) {
      fail(@"production_manager_rpcs3_loan", diagnostics); return;
    }
    std::memset(writer, 0x6d, target);
    if (!allBytes(reader, 0x6d) || api->unmap(token, reader) != 0 || api->unmap(token, writer) != 0 ||
        api->release(token) != 0) {
      fail(@"production_manager_actual_alias_data_and_release", diagnostics); return;
    }
    NSDictionary* after = NeoSwapRelay_Diagnostics();
    if ([after[@"liveBackingBytes"] unsignedLongLongValue] || [after[@"objectCount"] unsignedLongLongValue] ||
        [after[@"aliasCount"] unsignedLongLongValue] || [after[@"pendingCleanupEntries"] unsignedLongLongValue]) {
      fail(@"production_manager_release_loan_counts", after); return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      self.evidence[@"productionManagerPassed"] = @YES;
      self.evidence[@"productionManagerMainThreadNonblocking"] = @YES;
      self.evidence[@"productionManagerCapacityBytes"] = @(8ULL * 1024 * 1024 * 1024);
      self.evidence[@"productionManagerWrittenBytes"] = @(target);
      self.evidence[@"productionManagerRPCS3Only"] = @YES;
      self.evidence[@"productionManager"] = after;
      finish(self.evidence);
    });
  });
}
@end
int main(int argc, char* argv[]) {
  @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(RelayProbeApp.class)); }
}
'''


def validate_evidence(report: dict) -> None:
    if (not isinstance(report, dict) or type(report.get('schema')) is not int or report['schema'] != 1 or
            report.get('platform') != 'iOS18Simulator' or
            report.get('transport') != 'real-NSExtension-auxiliary-NSXPC'):
        raise RuntimeError('Invalid actual relay Simulator schema/platform/transport')
    for key in ('passed', 'creatorExitObserved', 'firstCreatorExitObserved', 'secondCreatorExitObserved',
                'aliasCoherencePassed', 'readOnlyAliasPassed', 'releaseWhileMappedRefused',
                'staleTokenRefused', 'releaseZeroingPassed', 'releasePassed', 'secondPreparationPassed',
                'productionManagerPassed', 'productionManagerMainThreadNonblocking', 'productionManagerRPCS3Only'):
        if report.get(key) is not True:
            raise RuntimeError('Missing actual relay lifecycle proof: ' + key)
    for key in ('realIPhoneValidated', 'realRPCS3GameplayValidated'):
        if report.get(key) is not False:
            raise RuntimeError('Simulator evidence must not claim physical iPhone/gameplay proof')
    pids = [report.get(key) for key in ('hostPID', 'creatorPID', 'secondCreatorPID')]
    if any(type(pid) is not int or pid <= 0 for pid in pids) or len(set(pids)) != 3:
        raise RuntimeError('Expected a real host and two distinct authenticated creator PIDs')
    expected = {'capacityBytes':TARGET_BYTES, 'writtenBytes':TARGET_BYTES,
                'aliasCountDuringUse':2, 'liveBytesDuringUse':TARGET_BYTES,
                'aliasedBytesDuringUse':2 * TARGET_BYTES, 'retainedBytesAfterRelease':TARGET_BYTES,
                'liveBytesAfterRelease':0, 'capacityBytesAfterShutdown':0,
                'pendingCleanupAfterShutdown':0, 'generation':1, 'secondGeneration':2,
                'productionManagerCapacityBytes':8*1024**3, 'productionManagerWrittenBytes':TARGET_BYTES}
    if any(type(report.get(key)) is not int or report[key] != value for key, value in expected.items()):
        raise RuntimeError('Actual relay counters do not match the complete two-preparation lifecycle')
    manager = report.get('productionManager')
    if (not isinstance(manager, dict) or manager.get('ready') is not True or
            manager.get('creatorExitObserved') is not True or manager.get('state') != 'ready' or
            manager.get('capacityBytes') != 8*1024**3 or manager.get('residentBytes') is not None):
        raise RuntimeError('Actual production manager did not publish post-exit capacity separately from residency')
    for key in ('liveBackingBytes', 'objectCount', 'aliasCount', 'pendingCleanupEntries'):
        if type(manager.get(key)) is not int or manager[key] != 0:
            raise RuntimeError('Actual production manager did not retire every probe loan')
    measured = manager.get('capabilityCheck')
    if (not isinstance(measured, dict) or measured.get('aliasDataVerified') is not True or
            measured.get('kind') != 'post_creator_exit_cpu_capability_check' or
            measured.get('requestedBytes') != 16 * 1024**2 or measured.get('gameplayValidated') is not False or
            type(measured.get('result')) is not int or measured['result'] != 0 or
            type(measured.get('cleanupResult')) is not int or measured['cleanupResult'] != 0):
        raise RuntimeError('Actual production manager capability check did not pass')
    ledger = [measured.get(key) for key in ('hostFootprintBeforeBytes', 'hostFootprintAfterBytes', 'hostFootprintDeltaBytes')]
    if (any(type(value) is not int or value < 0 for value in ledger) or
            ledger[2] != max(0, ledger[1] - ledger[0]) or ledger[2] >= 4 * 1024**2):
        raise RuntimeError('Actual production manager lacks its bounded host-footprint capability measurement')


# Same compatibility contract as validate_neoswap_ipa.py, checked on actual
# linked host/helper binaries before accepting either Apple preflight report.
OPTIONAL_MACH_IMPORTS = frozenset({
    '_mach_make_memory_entry_64', '_mach_vm_map', '_mach_vm_deallocate', '_mach_vm_purgable_control',
})


def validate_optional_mach_imports(undefined_symbols: str) -> None:
    eager = OPTIONAL_MACH_IMPORTS.intersection(undefined_symbols.split())
    if eager:
        raise RuntimeError('Optional Mach APIs must be resolved at runtime: ' + ', '.join(sorted(eager)))


def source_hashes() -> dict[str, str]:
    sources = list(RELAY.glob('*')) + [DONATION / 'Broker.cpp', DONATION / 'Broker.h',
        PUBLIC / 'NeoSwapRelay.h', PUBLIC / 'NeoSwapRelayService.h', PUBLIC / 'NeoSwapRelayService.mm',
        Path(__file__).resolve(),
        ROOT / 'build-utils/configure_neoswap_relay.py', ROOT / 'test/neoswap_donor_simulator_test.py',
        ROOT / 'build-utils/embed_rpcs3_host_entitlements.py']
    return {str(path.relative_to(ROOT)):hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources if path.is_file()}


def build(work: Path, sdk: str, report: dict, *, device: bool = False) -> Path:
    app = work / 'NeoSwapRelaySimulator.app'
    helper = app / 'PlugIns/NeoSwapPageRelay.appex'
    helper.mkdir(parents=True)
    harness = work / 'RelaySimulatorHost.mm'
    harness.write_text(HARNESS)
    canonical = work / 'canonical'
    shutil.copytree(RELAY, canonical / 'native/neoswap-relay')
    (canonical / 'native/neoswap-donation').mkdir()
    for name in ('Broker.cpp', 'Broker.h'):
        shutil.copyfile(DONATION / name, canonical / 'native/neoswap-donation' / name)
    host = canonical / 'packages/neo_swap/ios/Classes'
    host.mkdir(parents=True)
    for name in ('NeoSwapRelay.h', 'NeoSwapRelayService.h', 'NeoSwapRelayService.mm'):
        shutil.copyfile(PUBLIC / name, host / name)
    (host / 'Donation').mkdir()
    shutil.copyfile(DONATION / 'Broker.h', host / 'Donation/Broker.h')
    materialize(canonical)
    generated = canonical / 'ios/NeoSwapPageRelay'
    architecture = 'arm64' if device else platform.machine()
    if architecture not in ('arm64', 'x86_64'):
        raise RuntimeError('Unsupported native Apple runner architecture: ' + architecture)
    sdk_name = 'iphoneos' if device else 'iphonesimulator'
    suffix = '' if device else '-simulator'
    common = ['xcrun', '--sdk', sdk_name, 'clang++', '-x', 'objective-c++', '-std=c++20',
              '-O1', '-g', '-fobjc-arc', '-fblocks', '-Wall', '-Wextra', '-Werror',
              '-Wno-deprecated-declarations', '-isysroot', sdk,
              '-target', f'{architecture}-apple-ios18.0{suffix}',
              '-I', str(host / 'Relay'), '-I', str(DONATION), '-I', str(host), '-framework', 'Foundation']
    host_sources = [host / 'Relay/Backend.cpp', host / 'Relay/NeoSwapPageRelay.mm',
                    host / 'NeoSwapRelayService.mm', DONATION / 'Broker.cpp', harness]
    extension_sources = [generated / name for name in ('NeoSwapPageRelay.mm', 'NeoSwapPageRelayHandler.mm', 'Broker.cpp')]
    run(common + ['-framework', 'UIKit'] + list(map(str, host_sources)) + ['-o', str(app / 'NeoSwapRelaySimulator')], timeout=180)
    run(common + ['-DNEOSWAP_RELAY_EXTENSION=1', '-fapplication-extension', '-Wl,-e,_NSExtensionMain'] +
        list(map(str, extension_sources)) + ['-o', str(helper / 'NeoSwapPageRelay')], timeout=180)
    extension_symbols = run(['xcrun', 'nm', '-gU', str(helper / 'NeoSwapPageRelay')], capture=True)
    if '_OBJC_CLASS_$_NeoSwapPageRelaySession' in extension_symbols:
        raise RuntimeError('Extension must not contain the host launcher class')
    for executable in (app / 'NeoSwapRelaySimulator', helper / 'NeoSwapPageRelay'):
        validate_optional_mach_imports(run(['xcrun', 'nm', '-u', str(executable)], capture=True))
    host_info = {'CFBundleIdentifier':BUNDLE, 'CFBundleExecutable':'NeoSwapRelaySimulator',
                 'CFBundleName':'NeoSwapRelaySimulator', 'CFBundlePackageType':'APPL',
                 'CFBundleInfoDictionaryVersion':'6.0', 'CFBundleVersion':'1',
                 'CFBundleShortVersionString':'1.0', 'MinimumOSVersion':'18.0',
                 'CFBundleSupportedPlatforms':['iPhoneOS' if device else 'iPhoneSimulator'],
                 'UIDeviceFamily':[1, 2], 'LSRequiresIPhoneOS':True, 'UILaunchScreen':{},
                 'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait']}
    plist(app / 'Info.plist', host_info)
    helper_info = plistlib.loads((RELAY / 'Info.plist').read_bytes())
    helper_info.update({'CFBundleIdentifier':BUNDLE + RELAY_CONTRACT['bundleSuffix'],
                        'CFBundleExecutable':'NeoSwapPageRelay', 'CFBundleName':'NeoSwapPageRelay',
                        'CFBundleDevelopmentRegion':'en', 'CFBundleVersion':'1',
                        'CFBundleShortVersionString':'1.0',
                        'CFBundleSupportedPlatforms':host_info['CFBundleSupportedPlatforms']})
    if b'$(' in plistlib.dumps(helper_info):
        raise RuntimeError('Unresolved extension build setting in compiled probe')
    plist(helper / 'Info.plist', helper_info)
    report['buildPreflight'] = {'architecture':architecture, 'hostInfo':host_info, 'helperInfo':helper_info,
                              'hostLauncherAbsentFromExtension':True, 'optionalMachEagerImportsAbsent':True,
                              'sourceSHA256':source_hashes()}
    if device:
        for executable in (app / 'NeoSwapRelaySimulator', helper / 'NeoSwapPageRelay'):
            data = executable.read_bytes()
            if len(data) < 32 or struct.unpack_from('<II', data) != (0xFEEDFACF, 0x0100000C):
                raise RuntimeError('The actual device build is not arm64 Mach-O')
        report['buildPreflight']['deviceArm64Linked'] = True
        return app
    capabilities = RELAY / 'NeoSwapPageRelay.entitlements'
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(capabilities), str(helper)])
    signature = embedded_entitlements((helper / 'NeoSwapPageRelay').read_bytes())
    require_entitlements(signature, REQUIRED_RELAY_ENTITLEMENTS, 'NeoSwapPageRelay')
    if set(signature) != set(REQUIRED_RELAY_ENTITLEMENTS):
        raise RuntimeError('Unexpected relay production signature capabilities')
    empty = work / 'Simulator.entitlements'
    plist(empty, {})
    # Device-only memory capabilities are verified above. macOS AMFI rejects
    # them in Simulator, which therefore runs with an explicit empty signature.
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(empty), str(helper)])
    if embedded_entitlements((helper / 'NeoSwapPageRelay').read_bytes()):
        raise RuntimeError('Simulator retained device-only capabilities')
    run(['codesign', '--force', '--sign', '-', '--entitlements', str(empty), str(app)])
    run(['codesign', '--verify', '--deep', '--strict', '--verbose=2', str(app)])
    report['buildPreflight'].update({'productionCapabilitySignaturePreflight':signature,
        'simulatorEmbeddedEntitlements':{}, 'nestedSignatureVerified':True,
        'hostMachO':simulator_executable(app / 'NeoSwapRelaySimulator', architecture),
        'helperMachO':simulator_executable(helper / 'NeoSwapPageRelay', architecture)})
    return app


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--compile-device', action='store_true')
    arguments = parser.parse_args()
    output = arguments.output
    output.mkdir(parents=True, exist_ok=True)
    report = {'schema':1, 'passed':False, 'platform':'iOS18Simulator',
              'realIPhoneValidated':False, 'realRPCS3GameplayValidated':False,
              'source':subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()}
    device_id = None
    started = time.time()
    try:
        if sys.platform != 'darwin':
            raise RuntimeError('A real macOS runner is mandatory; the native proof cannot be skipped')
        with tempfile.TemporaryDirectory(prefix='neoswap-relay-simulator-') as directory:
            if arguments.compile_device:
                sdk = run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture=True).strip()
                report['platform'] = 'iOS18-arm64-compile-only'
                build(Path(directory), sdk, report, device=True)
                report['passed'] = True
                return 0
            sdk, runtime, sdk_version = sdk_runtime()
            report.update({'runtime':runtime, 'sdkVersion':sdk_version, 'stage':'build'})
            app = build(Path(directory), sdk, report)
            (output / 'preflight.json').write_text(json.dumps(report, indent=2) + '\n')
            (output / 'RelaySimulatorHost.mm').write_text(HARNESS)
            device_id = run(['xcrun', 'simctl', 'create', 'NeoSwapRelayProof',
                'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro', runtime], capture=True).strip()
            run(['xcrun', 'simctl', 'boot', device_id])
            run(['xcrun', 'simctl', 'bootstatus', device_id, '-b'], timeout=180)
            run(['xcrun', 'simctl', 'install', device_id, str(app)], timeout=180)
            container = Path(run(['xcrun', 'simctl', 'get_app_container', device_id, BUNDLE, 'data'], capture=True).strip())
            report['stage'] = 'launch'
            launch = collect_launch_evidence(['xcrun', 'simctl', 'launch', device_id, BUNDLE],
                                            container / 'Documents/relay-simulator.json')
            native = launch.pop('runtimeEvidence')
            report.update(native)
            report.update(launch)
            validate_evidence(report)
            report['stage'] = 'complete'
            print(json.dumps(report, indent=2))
            return 0
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        report['passed'] = False
        report['runnerError'] = str(error)
        print(str(error), file=sys.stderr)
        if device_id:
            try:
                report['simulatorLogs'] = run(['xcrun', 'simctl', 'spawn', device_id, 'log', 'show',
                    '--last', '3m', '--info', '--debug', '--style', 'compact', '--predicate',
                    'process IN {"NeoSwapPageRelay", "NeoSwapRelaySimulator"} OR eventMessage CONTAINS[c] "NeoSwapPageRelay"'],
                    capture=True, timeout=40)[-40000:]
            except subprocess.SubprocessError as log_error:
                report['simulatorLogError'] = str(log_error)
            crash_roots = [Path.home() / 'Library/Logs/DiagnosticReports',
                Path.home() / 'Library/Developer/CoreSimulator/Devices' / device_id / 'data/Library/Logs/CrashReporter']
            for root in crash_roots:
                for crash in root.glob('NeoSwap*'):
                    if crash.is_file() and crash.suffix in ('.ips', '.crash') and crash.stat().st_mtime >= started:
                        shutil.copyfile(crash, output / crash.name)
        return 1
    finally:
        name = 'arm64-report.json' if arguments.compile_device else 'report.json'
        (output / name).write_text(json.dumps(report, indent=2) + '\n')
        if device_id:
            for action in ('shutdown', 'delete'):
                try:
                    run(['xcrun', 'simctl', action, device_id], capture=True, timeout=20)
                except subprocess.SubprocessError as error:
                    print(f'Own Simulator cleanup: {error}', file=sys.stderr)
        (output / ('arm64-runner.log' if arguments.compile_device else 'runner.log')).write_text('\n'.join(LOGS))


if __name__ == '__main__':
    raise SystemExit(main())
