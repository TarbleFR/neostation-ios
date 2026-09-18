#!/usr/bin/env python3
"""Build 283: bound RPCS3 host diagnostics after the established host stack."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
HOST = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
MARKER = 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG'


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f'{label}: expected one source anchor, found {count}')
    return text.replace(old, new, 1)


def main() -> None:
    text = HOST.read_text()
    if MARKER in text:
        print('Build 283 RPCS3 host diagnostics already applied')
        return

    if '#import <os/lock.h>' not in text:
        text = replace_once(
            text,
            '#import <errno.h>\n',
            '#import <errno.h>\n#import <os/lock.h>\n',
            'os lock import',
        )

    old = '''static void RPCS3Log(void* context, int32_t level, const char* message) {
  Rpcs3InternalBridgePlugin* bridge = (__bridge Rpcs3InternalBridgePlugin*)context;
  if (!bridge || !message) return;
  // NEOSTATION_BUILD265_COREPROF_LOG: retain the sampled profiler summaries
  // without enabling the high-volume debug/trace stream or any Dart events.
  if (level > 5 && strstr(message, "COREPROF ") == nullptr &&
      strstr(message, "COREPROF_RESILIENCE ") == nullptr) return;
  NSString* text = [NSString stringWithUTF8String:message] ?: @"";
  // Keep notices/errors needed for crash diagnosis; do not fsync debug/trace
  // output on the render or emulation hot paths.
  // Level 5 includes PPU linking / relocation and SPU worker milestones.
  // Dart has no coreLog consumer. Do not flood its main queue with events
  // while native boot callbacks are waiting for that same queue.
  RPCS3Diagnostic(@"core_log", text);
}'''
    new = '''static void RPCS3Log(void* context, int32_t level, const char* message) {
  Rpcs3InternalBridgePlugin* bridge = (__bridge Rpcs3InternalBridgePlugin*)context;
  if (!bridge || !message) return;

  // NEOSTATION_BUILD283_BOUNDED_CORE_LOG
  const BOOL profiler =
      strstr(message, "COREPROF ") != nullptr ||
      strstr(message, "COREPROF_RESILIENCE ") != nullptr;
  if (level > 2 && !profiler) return;

  static os_unfair_lock budgetLock = OS_UNFAIR_LOCK_INIT;
  static CFTimeInterval budgetWindow = 0;
  static uint32_t budgetCount = 0;
  if (!profiler) {
    const CFTimeInterval now = CACurrentMediaTime();
    BOOL allowed = YES;
    os_unfair_lock_lock(&budgetLock);
    if (budgetWindow == 0 || now - budgetWindow >= 1.0) {
      budgetWindow = now;
      budgetCount = 0;
    }
    if (budgetCount >= 128) allowed = NO;
    else budgetCount++;
    os_unfair_lock_unlock(&budgetLock);
    if (!allowed) return;
  }

  NSString* text = [NSString stringWithUTF8String:message] ?: @"";
  RPCS3Diagnostic(@"core_log", text);
}'''
    text = replace_once(text, old, new, 'bounded Core logger')

    for stage in (
        'core_load_begin', 'core_load_end',
        'core_initialize_begin', 'core_initialize_end',
        'llvm_self_test_begin', 'llvm_self_test_end',
        'game_boot_begin', 'game_boot_return',
    ):
        text = replace_once(
            text,
            f'RPCS3Diagnostic(@"{stage}"',
            f'RPCS3Milestone(@"{stage}"',
            f'{stage} milestone',
        )

    HOST.write_text(text)
    print('Build 283 RPCS3 bounded diagnostics + durable milestones applied')


if __name__ == '__main__':
    main()
