#!/usr/bin/env python3
"""Apply after the verified 271/267 rollback. No core or JIT protocol changes.

Games may only observe a TCP endpoint. Native VPN mutation belongs exclusively
 to manual ON/OFF. Optional logging is never a dependency of core readiness.
"""
from pathlib import Path
import hashlib
import json

ROOT = Path(__file__).resolve().parents[1]


def replace(name, old, new):
    path = ROOT / name
    text = path.read_text()
    if new and new in text:
        return
    if not new and old not in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f'{name}: expected one 271 source anchor: {old[:90]}')
    path.write_text(text.replace(old, new, 1))


VPN_ENTRY = r'''  // NEOSTATION_VPN_USER_CHOICE_272: observation never mutates VPN profiles.
  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      // TCP first, including when our profile, signing or preferences are absent.
      // Do not enter the manual transaction queue: its error cleanup can stop VPN.
      self.probeJitRoute { ready in
        NeoStationVPNDiagnostics.record("route", ready
          ? "NEOSTATION_VPN_USER_CHOICE_272: endpoint reachable; VPN unchanged"
          : "NEOSTATION_VPN_USER_CHOICE_272: endpoint unavailable; VPN unchanged")
        if ready { completion(.success(self.externalRouteResponse())) }
        else { completion(.failure(.routeUnavailable)) }
      }
    }
  }
  func enableOwned(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      if let previous = self.current, previous.intent == "activate-owned" {
        previous.waiters.append(completion); return
      }
      let request = self.begin("activate-owned", seconds: 30, completion: completion)
      if let manager = self.activeManager, manager.connection.status == .connected {
        self.verify(manager, request); return
      }
      self.loadForStart(request)
    }
  }

'''

SERVICE = "import 'dart:io';\nimport 'package:flutter/services.dart';\nimport 'package:stikjit_bridge/stikjit_bridge.dart';\n\n/// NEOSTATION_VPN_SERVICE_272. Read-only preflight and manual commands never mix.\nclass LocalJitTunnelService {\n  LocalJitTunnelService._();\n\n  static Future<LocalJitTunnelState> status() async {\n    try {\n      return await StikjitBridge.localTunnelStatus();\n    } on PlatformException catch (error) {\n      throw _error(error);\n    }\n  }\n\n  /// This is the only game/JIT entry: TCP observation, no preferences or control.\n  static Future<LocalJitTunnelState> ensureRunningForJit() async {\n    if (!Platform.isIOS) {\n      throw const LocalJitTunnelException('unsupportedPlatform', 'Local JIT requires iOS.');\n    }\n    try {\n      return await StikjitBridge.ensureJitRoute();\n    } on PlatformException catch (error) {\n      throw _error(error);\n    }\n  }\n\n  /// Manual settings action only. iOS manages switching away from other VPNs.\n  static Future<LocalJitTunnelState> authorizeAndEnable() async {\n    try {\n      return await StikjitBridge.activateOwnedTunnel();\n    } on PlatformException catch (error) {\n      throw _error(error);\n    }\n  }\n\n  /// Manual settings action only. Native cancellation is bounded and immediate.\n  static Future<LocalJitTunnelState> disable() async {\n    try {\n      return await StikjitBridge.disableLocalTunnel();\n    } on PlatformException catch (error) {\n      throw _error(error);\n    }\n  }\n\n  // Compatibility hooks: lifecycle must never start, stop, save or probe a VPN.\n  static Future<void> refreshInBackground({required String reason}) async {}\n  static Future<void> stopForLifecycle({required String reason}) async {}\n\n  static LocalJitTunnelException _error(PlatformException error) =>\n      LocalJitTunnelException(error.code, error.message ?? 'The selected VPN route is unavailable.');\n}\n\nclass LocalJitTunnelException implements Exception {\n  const LocalJitTunnelException(this.code, this.message);\n  final String code;\n  final String message;\n  @override\n  String toString() => message;\n}\n"

LOGGER = r'''#pragma once
#import <Foundation/Foundation.h>
#include <atomic>

// NEOSTATION_RPCS3_ASYNC_DIAGNOSTICS_272. Best-effort milestones only.
// Sudden process termination may lose pending lines; no runtime path drains us.
static inline dispatch_queue_t RPCS3DiagnosticQueue() {
  static dispatch_queue_t queue;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create("neostation.rpcs3.diagnostics.async272",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  });
  return queue;
}
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  if ([stage isEqualToString:@"core_log"] || [stage isEqualToString:@"performance_sample"]) return;
  static std::atomic<unsigned> pending{0};
  if (pending.fetch_add(1, std::memory_order_relaxed) >= 128) {
    pending.fetch_sub(1, std::memory_order_relaxed); return;
  }
  NSString* safeStage = [(stage ?: @"") substringToIndex:MIN(stage.length, (NSUInteger)128)];
  NSString* safeMessage = [(message ?: @"") substringToIndex:MIN(message.length, (NSUInteger)2048)];
  const NSTimeInterval time = NSDate.date.timeIntervalSince1970;
  dispatch_async(RPCS3DiagnosticQueue(), ^{
    @autoreleasepool {
      NSFileHandle* file = nil;
      @try {
        NSString* documents = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* path = [documents stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
        if (!path) return;
        NSDictionary* entry = @{@"timestamp": @(time), @"stage": safeStage, @"message": safeMessage};
        NSData* data = [NSJSONSerialization dataWithJSONObject:entry options:0 error:nil];
        if (!data) return;
        NSMutableData* line = [data mutableCopy]; [line appendBytes:"\n" length:1];
        if (![NSFileManager.defaultManager fileExistsAtPath:path])
          [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
        file = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!file) return;
        const unsigned long long length = [file seekToEndOfFile];
        if (length + line.length > 2 * 1024 * 1024) {
          [file truncateFileAtOffset:0]; [file seekToFileOffset:0];
        }
        [file writeData:line];
      } @catch (__unused NSException* exception) {
        // Diagnostic failures cannot fail core startup or imports.
      } @finally {
        @try { [file closeFile]; } @catch (__unused NSException* ignored) {}
        pending.fetch_sub(1, std::memory_order_relaxed);
      }
    }
  });
}
'''

NATIVE_TEST = r'''#import <Foundation/Foundation.h>
#include <cassert>
static NSString* testDocuments;
#define NSSearchPathForDirectoriesInDomains(...) (@[testDocuments])
#import "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h"
#undef NSSearchPathForDirectoriesInDomains
// Draining is TEST-ONLY; production must never wait for its diagnostic queue.
static void drain() { dispatch_sync(RPCS3DiagnosticQueue(), ^{}); }
static NSArray* entries(NSString* path) {
  NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  assert(text && [text hasSuffix:@"\n"]);
  NSMutableArray* rows = [NSMutableArray new];
  for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
    if (!line.length) continue;
    id value = [NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    assert([value isKindOfClass:NSDictionary.class]); [rows addObject:value];
  }
  return rows;
}
int main(int argc, const char* argv[]) {
  @autoreleasepool {
    assert(argc == 2); testDocuments = [NSString stringWithUTF8String:argv[1]];
    NSString* path = [testDocuments stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
    dispatch_semaphore_t entered = dispatch_semaphore_create(0), release = dispatch_semaphore_create(0);
    dispatch_async(RPCS3DiagnosticQueue(), ^{
      dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    });
    assert(dispatch_semaphore_wait(entered, dispatch_time(DISPATCH_TIME_NOW, 3*NSEC_PER_SEC)) == 0);
    const NSTimeInterval start = NSDate.date.timeIntervalSince1970;
    for (int i=0; i<1000; ++i) RPCS3Diagnostic(@"core_log", @"suppressed");
    for (int i=0; i<500; ++i) RPCS3Diagnostic(@"boot", @"bounded");
    assert(NSDate.date.timeIntervalSince1970-start < 1.0);
    assert(![NSFileManager.defaultManager fileExistsAtPath:path]);
    dispatch_semaphore_signal(release); drain();
    assert(entries(path).count == 128);
    RPCS3Diagnostic(@"core_load_begin", @"test milestone"); drain();
    assert([entries(path).lastObject[@"stage"] isEqualToString:@"core_load_begin"]);
    assert([NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".old"] error:nil]);
    RPCS3Diagnostic(@"boot", @"reopen"); drain(); assert(entries(path).count == 1);
    NSString* large = [@"x" stringByPaddingToLength:4096 withString:@"x" startingAtIndex:0];
    for (int i=0; i<1200; ++i) { RPCS3Diagnostic(@"boot", large); drain(); }
    assert([[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize] <= 2*1024*1024);
    RPCS3Diagnostic(nil, nil); drain(); assert([entries(path).lastObject[@"stage"] isEqualToString:@""]);
    puts("PASS: 272 asynchronous milestones, blocked-sink isolation, bounded queue, rotation, suppressed verbose logs");
  }
}
'''


def main():
    manager = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    p = ROOT / manager
    text = p.read_text()
    if 'NEOSTATION_VPN_USER_CHOICE_272' not in text:
        start = text.index('  func ensureRunning(')
        end = text.index('  func status(', start)
        p.write_text(text[:start] + VPN_ENTRY + text[end:])
    replace(manager, '"status": "externalRoute"', '"status": "reachableRoute"')
    # Keep on-demand disabled: it could otherwise take the connection back from
    # LocalDevVPN. Persist the system profile, never fabricate an active UI flag.
    service = 'lib/services/local_jit_tunnel_service.dart'
    (ROOT / service).write_text(SERVICE)
    lifecycle = 'lib/widgets/app_lifecycle_handler.dart'
    text = (ROOT / lifecycle).read_text()
    if 'local_jit_tunnel_service.dart' in text:
        for target in ("import 'dart:async';\n", "import 'package:neostation/services/local_jit_tunnel_service.dart';\n", "import 'package:neostation/services/local_jit_lifecycle_policy.dart';\n"):
            text = text.replace(target, '')
        blocks = [
            "        if (Platform.isIOS) {\n          await LocalJitTunnelService.stopForLifecycle(\n            reason: 'normal app exit',\n          );\n        }\n",
            "    if (Platform.isIOS) {\n      unawaited(\n        LocalJitTunnelService.stopForLifecycle(reason: 'lifecycle disposed'),\n      );\n    }\n",
            "      // Begin route selection immediately. This probes an existing external\n      // LocalDevVPN route before deciding whether NeoStationLocalTunnel is\n      // needed, while the rest of resume housekeeping proceeds normally.\n      if (Platform.isIOS) {\n        unawaited(\n          LocalJitTunnelService.refreshInBackground(reason: 'app resume'),\n        );\n      }\n",
            "    // AppLifecycleState.inactive can be a native VPN permission dialog, not\n    // a background transition. Do not invalidate the authorization it awaits.\n    // Only detached is an unambiguous teardown, not a helper transition.\n    if (Platform.isIOS && shouldStopLocalJitForLifecycle(state)) {\n      unawaited(\n        LocalJitTunnelService.stopForLifecycle(\n          reason: 'app lifecycle ${state.name}',\n        ),\n      );\n    }\n",
        ]
        for block in blocks:
            if block not in text: raise RuntimeError('Unexpected lifecycle source')
            text = text.replace(block, '', 1)
        text = text.replace('On iOS explicit teardown stops NeoStationLocalTunnel; helper transitions do not.', 'VPN profiles and tunnels are independent of this widget and app lifetime.')
        (ROOT / lifecycle).write_text(text)
    app = 'lib/main.dart'
    replace(app, "import 'package:neostation/services/local_jit_tunnel_service.dart';\n", '')
    replace(app, "  if (Platform.isIOS) {\n    // The system-owned Packet Tunnel continues outside the Flutter lifecycle.\n    // Do not delay the frontend while iOS restores or authorizes it.\n    unawaited(\n      LocalJitTunnelService.refreshInBackground(reason: 'cold start'),\n    );\n  }\n", '')
    # No observer may stop the tunnel, even on detached/dispose/normal exit.
    policy = ROOT / 'lib/services/local_jit_lifecycle_policy.dart'
    policy.write_text("import 'package:flutter/widgets.dart';\n\n// Only an explicit settings action may stop the VPN.\nbool shouldStopLocalJitForLifecycle(AppLifecycleState state) => false;\n")
    policytest = ROOT / 'test/local_jit_lifecycle_policy_test.dart'
    policytest.write_text("import 'package:flutter/widgets.dart';\nimport 'package:flutter_test/flutter_test.dart';\nimport 'package:neostation/services/local_jit_lifecycle_policy.dart';\nvoid main() {\n  test('all lifecycle transitions preserve user VPN choice', () {\n    for (final state in AppLifecycleState.values) {\n      expect(shouldStopLocalJitForLifecycle(state), isFalse, reason: state.name);\n    }\n  });\n}\n")
    bridge = 'packages/stikjit_bridge/lib/stikjit_bridge.dart'
    replace(bridge, "invokeMethod<Object?>('ensureLocalTunnel').timeout(\n      const Duration(seconds: 35)",
                    "invokeMethod<Object?>('ensureLocalTunnel').timeout(\n      const Duration(seconds: 3)")
    replace(bridge, 'build=271; bridge=ensureLocalTunnel; no native response after 35s.',
                    'build=272; bridge=ensureLocalTunnel; read-only probe did not respond after 3s.')
    runtime = ROOT / 'lib/services/rpcs3_internal_service.dart'
    text = runtime.read_text()
    if 'READ_ONLY_PREFLIGHT_272' not in text:
        a = text.index('    var readingProgress = false;')
        b = text.index('    if (jit[\'success\'] != true)', a)
        block = text[a:b]
        start = block.index('      jit = await _bounded(')
        end = block.index('\n    } finally', start)
        call = block[start:end].replace('      jit =', '    final jit =', 1)
        text = text[:a] + '    // READ_ONLY_PREFLIGHT_272: one preflight; no optional status polling.\n' + call + '\n' + text[b:]
        text = text.replace('NeoStation will refresh ', 'Select the VPN you want to use ')
        text = text.replace("'its integrated local JIT tunnel automatically before retrying. '", "'in settings before retrying; no VPN is changed automatically. '")
        runtime.write_text(text)
    helper = 'packages/rpcs3_jit_helper/ios/Classes/Rpcs3JITRequestHandlerBase.swift'
    replace(helper, '''  ) throws {
    sendLock.lock()''', '''  ) throws {
    // NEOSTATION_RPCS3_OPTIONAL_LOGS_OFF_272. Never block StikJIT on diagnostics.
    // helper_connected, pid_attached and complete remain reliable and unchanged.
    if event == "log" { return }
    sendLock.lock()''')
    (ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h').write_text(LOGGER)
    (ROOT / 'test/native/rpcs3_diagnostics_test.mm').write_text(NATIVE_TEST)
    journal = 'packages/stikjit_bridge/ios/Classes/NeoStationVPNDiagnostics.swift'
    replace(journal, 'try file.write(contentsOf: Data(text.utf8)); try file.synchronize()',
                     'try file.write(contentsOf: Data(text.utf8))')
    replace(journal, 'VPN=271', 'VPN=272-manual-only')
    # The immutable core includes ordinary cached-shader restoration, not a new
    # whole-title offline compile. Do not disable it or invalidate shader caches.
    print('Build 272 applied: manual-only VPN, persistent system state, one read-only preflight, asynchronous milestones, unchanged two-phase JIT and shader/core caches.')


if __name__ == '__main__':
    main()
