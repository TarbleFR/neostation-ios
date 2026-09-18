#!/usr/bin/env python3
"""Build 274 RPCS3 launch-path stabilization.

Applied after Build 273. It keeps VPN ownership manual, makes the route check a
single bounded stability gate before JIT, removes status polling/revalidation
from the RPCS3 boot path, caches the memory-layout preflight for the process
lifetime, shortens helper-only watchdogs, and makes native diagnostics fully
asynchronous.
"""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def read(name: str) -> str:
    return (ROOT / name).read_text()

def write(name: str, text: str) -> None:
    (ROOT / name).write_text(text)

def change(name: str, old: str, new: str) -> None:
    text = read(name)
    if new in text:
        return
    if text.count(old) != 1:
        raise RuntimeError(f"{name}: unexpected source anchor: {old[:100]!r}")
    write(name, text.replace(old, new, 1))

VPN_PREFLIGHT = r'''  // NEOSTATION_VPN_STABLE_PREFLIGHT_274: one bounded gate before JIT.
  // This is still observation-only: no preference load/save/start/stop occurs.
  func ensureRunning(completion: @escaping (Response) -> Void) {
    DispatchQueue.main.async {
      self.probeJitRoute { firstReady in
        guard firstReady else {
          NeoStationVPNDiagnostics.record(
            "route",
            "NEOSTATION_VPN_STABLE_PREFLIGHT_274: initial route unavailable; VPN unchanged"
          )
          completion(.failure(.routeUnavailable))
          return
        }

        // A just-established packet tunnel can answer one TCP SYN while the
        // RemotePairing path is still settling. Confirm the same route once,
        // before RPCS3/StikJIT starts, then never touch the VPN during boot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
          self.probeJitRoute { stable in
            NeoStationVPNDiagnostics.record(
              "route",
              stable
                ? "NEOSTATION_VPN_STABLE_PREFLIGHT_274: route stable; VPN frozen for RPCS3 boot"
                : "NEOSTATION_VPN_STABLE_PREFLIGHT_274: route changed during preflight; VPN unchanged"
            )
            if stable {
              completion(.success(self.externalRouteResponse()))
            } else {
              completion(.failure(.routeUnavailable))
            }
          }
        }
      }
    }
  }

'''

DIAGNOSTICS = r'''#pragma once

#import <Foundation/Foundation.h>

// Build 274: diagnostics are strictly off the RPCS3/JIT hot path.
// The caller only enqueues an immutable record; serialized file I/O happens on
// a utility queue and never fsyncs or blocks Core initialization/game boot.
static inline void RPCS3Diagnostic(NSString* stage, NSString* message) {
  static dispatch_queue_t queue;
  static NSString* path;
  static NSFileHandle* file;
  static unsigned long long length = 0;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    queue = dispatch_queue_create(
        "com.neogamelab.neostation.rpcs3.diagnostics",
        DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(
        queue,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    NSString* documents = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    path = [documents stringByAppendingPathComponent:@"RPCS3-diagnostic.log"];
  });

  NSString* stageCopy = [stage copy] ?: @"";
  NSString* messageCopy = [message copy] ?: @"";
  NSTimeInterval timestamp = [NSDate.date timeIntervalSince1970];

  dispatch_async(queue, ^{
    @autoreleasepool {
      if (!path) return;
      @try {
        if (!file) {
          NSFileManager* files = NSFileManager.defaultManager;
          if (![files fileExistsAtPath:path]) {
            [files createFileAtPath:path contents:nil attributes:nil];
          }
          file = [NSFileHandle fileHandleForWritingAtPath:path];
          if (!file) return;
          length = [file seekToEndOfFile];
        }

        NSDictionary* entry = @{
          @"timestamp": @(timestamp),
          @"stage": stageCopy,
          @"message": messageCopy,
        };
        NSData* json = [NSJSONSerialization dataWithJSONObject:entry
                                                       options:0
                                                         error:nil];
        if (!json) return;
        NSMutableData* line = [json mutableCopy];
        [line appendBytes:"\n" length:1];
        if (length + line.length > 2 * 1024 * 1024) {
          [file truncateFileAtOffset:0];
          [file seekToFileOffset:0];
          length = 0;
        }
        [file writeData:line];
        length += line.length;
      } @catch (__unused NSException* exception) {
        @try { [file closeFile]; } @catch (__unused NSException* ignored) {}
        file = nil;
        length = 0;
      }
    }
  });
}
'''

def main() -> None:
    # 1. One bounded route stability gate before the JIT transaction.
    manager_name = 'packages/stikjit_bridge/ios/Classes/NeoStationLocalTunnelManager.swift'
    manager = read(manager_name)
    if 'NEOSTATION_VPN_STABLE_PREFLIGHT_274' not in manager:
        start = manager.index('  func ensureRunning(')
        end = manager.index('  // Explicit Settings ON', start)
        manager = manager[:start] + VPN_PREFLIGHT + manager[end:]
        write(manager_name, manager)

    # 2. Remove one-second JIT status polling and the redundant post-attach
    # status round-trip. prepareJit already returns the authoritative debugged
    # state from the native transaction.
    service_name = 'lib/services/rpcs3_internal_service.dart'
    service = read(service_name)
    old = r'''    var readingProgress = false;
    final progress = Timer.periodic(const Duration(seconds: 1), (_) async {
      if (readingProgress) return;
      readingProgress = true;
      try {
        final status = await _jitStatus();
        final message = status['message']?.toString() ?? '';
        if (_state.phase == Rpcs3RuntimePhase.enablingJit &&
            message.isNotEmpty &&
            message != _state.message) {
          _emit(Rpcs3RuntimePhase.enablingJit, message, jitReady: false);
        }
      } catch (_) {
        // Progress is optional; the transaction reports the authoritative error.
      } finally {
        readingProgress = false;
      }
    });
    late final Map<String, dynamic> jit;
    try {
      jit = await _bounded(
        Rpcs3InternalBridge.prepareJit(pairingFilePath: pairing.path),
        _jitTimeout,
        'jitTimeout',
        'La préparation StikJIT/DDI ne répond plus. Relancez NeoStation avant de réessayer.',
      );
    } finally {
      progress.cancel();
    }
    if (jit['success'] != true) {
      final rawMessage =
          jit['message']?.toString() ??
          'StikJIT could not enable JIT for NeoStation.';
      throw Rpcs3InternalException(
        'jitFailed',
        _actionableJitFailure(rawMessage),
      );
    }

    _jitCompletionPending = jit['requiresCompletion'] == true;

    final status = await _jitStatus();
    if (status['debugged'] != true) {
      throw const Rpcs3InternalException(
        'jitNotPersistent',
        'RPCS3 JIT did not remain active after StikJIT detached.',
      );
    }

'''
    new = r'''    final jit = await _bounded(
      Rpcs3InternalBridge.prepareJit(pairingFilePath: pairing.path),
      _jitTimeout,
      'jitTimeout',
      'La préparation StikJIT/DDI ne répond plus. Relancez NeoStation avant de réessayer.',
    );
    if (jit['success'] != true) {
      final rawMessage =
          jit['message']?.toString() ??
          'StikJIT could not enable JIT for NeoStation.';
      throw Rpcs3InternalException(
        'jitFailed',
        _actionableJitFailure(rawMessage),
      );
    }
    if (jit['debugged'] != true) {
      throw const Rpcs3InternalException(
        'jitNotPersistent',
        'RPCS3 JIT did not remain active after the initial StikJIT attach.',
      );
    }

    _jitCompletionPending = jit['requiresCompletion'] == true;

'''
    if 'after the initial StikJIT attach' not in service:
        if service.count(old) != 1:
            raise RuntimeError('RPCS3 Dart JIT polling block changed unexpectedly')
        service = service.replace(old, new, 1)
        write(service_name, service)

    # 3. Keep long DDI preparation available, but reduce watchdog time spent
    # around the short helper-connect/detach phases.
    bridge_name = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3JitBridgePlugin.mm'
    change(bridge_name,
           'static NSTimeInterval const kRpcs3HelperConnectTimeout = 30.0;',
           'static NSTimeInterval const kRpcs3HelperConnectTimeout = 12.0;')
    change(bridge_name,
           'static NSTimeInterval const kRpcs3CompletionTimeout = 120.0;',
           'static NSTimeInterval const kRpcs3CompletionTimeout = 45.0;')

    # 4. Cache a successful virtual-layout preflight for this process. The Core
    # itself remains the owner of its JIT arena; NeoStation does not re-probe
    # the layout on every later management/launch request.
    core_name = 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
    core = read(core_name)
    prop_old = '@property(nonatomic, assign) BOOL llvmSelfTestPassed;\n@end'
    prop_new = '@property(nonatomic, assign) BOOL llvmSelfTestPassed;\n@property(nonatomic, assign) BOOL memoryPreflightPassed;\n@end'
    if 'memoryPreflightPassed' not in core:
        if core.count(prop_old) != 1:
            raise RuntimeError('RPCS3 memory preflight property anchor changed')
        core = core.replace(prop_old, prop_new, 1)

    preflight_old = r'''      RPCS3Diagnostic(@"memory_preflight_begin", @"Checking RPCS3 virtual address space before JIT attachment");
      BOOL available = self.initialized || neostation::rpcs3::probe_virtual_layout();
      NSString* message = available ? @"RPCS3 virtual memory layout available." :
          @"iOS refuse l’espace mémoire requis par RPCS3. Réinstallez l’IPA en conservant le droit extended-virtual-addressing lors de la signature. Journal : RPCS3-diagnostic.log.";
      RPCS3Diagnostic(@"memory_preflight_end", message);
'''
    preflight_new = r'''      BOOL available = self.initialized || self.memoryPreflightPassed;
      if (!available) {
        RPCS3Diagnostic(@"memory_preflight_begin", @"Checking RPCS3 virtual address space once before JIT attachment");
        available = neostation::rpcs3::probe_virtual_layout();
        self.memoryPreflightPassed = available;
        RPCS3Diagnostic(
            @"memory_preflight_end",
            available
                ? @"RPCS3 virtual memory layout validated and cached for this process."
                : @"RPCS3 virtual memory layout unavailable.");
      }
      NSString* message = available
          ? @"RPCS3 virtual memory layout available."
          : @"iOS refuse l’espace mémoire requis par RPCS3. Réinstallez l’IPA en conservant le droit extended-virtual-addressing lors de la signature. Journal : RPCS3-diagnostic.log.";
'''
    if 'validated and cached for this process' not in core:
        if core.count(preflight_old) != 1:
            raise RuntimeError('RPCS3 memory preflight block changed unexpectedly')
        core = core.replace(preflight_old, preflight_new, 1)
    write(core_name, core)

    # 5. Never perform synchronous diagnostic I/O on JIT/Core/gameplay paths.
    write('packages/rpcs3_internal_bridge/ios/Classes/Rpcs3Diagnostics.h', DIAGNOSTICS)

    print('Build 274: stable one-shot VPN gate, one JIT attach path, cached memory preflight, reduced watchdogs, async diagnostics.')

if __name__ == '__main__':
    main()
