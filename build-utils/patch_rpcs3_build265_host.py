#!/usr/bin/env python3
"""Keep sampled RPCS3 profiles while respecting Build 283's bounded host logger."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FILE = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
MARKER = 'NEOSTATION_BUILD283_BOUNDED_CORE_LOG'


def main() -> None:
    text = FILE.read_text()
    if MARKER in text:
        print('Build 283 bounded RPCS3 Core logging already present')
        return

    old = '  if (!bridge || !message || level > 5) return;'
    if text.count(old) != 1:
        raise SystemExit('Unexpected RPCS3Log filter')

    replacement = '''  if (!bridge || !message) return;
  // NEOSTATION_BUILD283_BOUNDED_CORE_LOG
  const BOOL profiler =
      strstr(message, "COREPROF ") != nullptr ||
      strstr(message, "COREPROF_RESILIENCE ") != nullptr;
  if (level > 2 && !profiler) return;'''
    text = text.replace(old, replacement, 1)
    if '#import <string.h>' not in text:
        text = '#import <string.h>\n' + text
    FILE.write_text(text)
    print('Build 283 bounded RPCS3 Core logging applied')


if __name__ == '__main__':
    main()
